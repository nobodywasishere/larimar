module Larimar
  # A message from the client answering a request sent to it
  alias ClientResponse = LSProtocol::Response | LSProtocol::ResponseMessage | LSProtocol::ResponseErrorMessage

  # Returns `true` if a notification with the given *method* may be ignored,
  # i.e. if it starts with `$/`, as per the LSP specification.
  def self.ignorable_notification?(method : String) : Bool
    method.starts_with?("$/")
  end
end

class Larimar::Server
  Log = ::Larimar::Log.for(self)

  DEFAULT_CONTENT_TYPE = "application/vscode-jsonrpc; charset=utf-8"

  # Raised when a received message can't be handled, answering it
  # with an error if it's a request, as identified by its *id*.
  class MessageError < Exception
    getter id : Int32 | String | Nil
    getter code : LSProtocol::ErrorCodes

    # The method of the message, if it's a string
    getter method : String?

    def initialize(@id, @code, message : String, @method = nil)
      super(message)
    end

    # Returns `true` if it's about a notification which may be ignored.
    #
    # See `Larimar.ignorable_notification?`.
    def ignorable? : Bool
      id.nil? && !!method.try { |method| Larimar.ignorable_notification?(method) }
    end

    # Returns the response answering the request it's about with it, with
    # the given error *code*, or `nil` if it's not about a request.
    def response(code : LSProtocol::ErrorCodes = self.code) : LSProtocol::ResponseErrorMessage?
      return unless (id = self.id)

      LSProtocol::ResponseErrorMessage.new(
        id: id,
        error: LSProtocol::ResponseError.new(
          code: code.value,
          message: message || code.to_s
        )
      )
    end
  end

  getter input : IO
  getter output : IO
  @output_lock = Mutex.new(:reentrant)

  # How long after the shutdown request to exit, in case the client
  # doesn't send the exit notification; `nil` disables it
  property shutdown_exit_delay : Time::Span? = 3.seconds

  def initialize(@input : IO, @output : IO)
  end

  # Serves *controller* until the input gets closed.
  def start(controller : Larimar::Controller) : Nil
    controller.server = self

    Log.info { "Starting server..." }

    return unless handshake(controller)

    Log.info { "Connected successfully." }

    server_loop(controller)
  end

  # Returns `false` if the input got closed before the initialization.
  def handshake(controller : Larimar::Controller) : Bool
    loop do
      init_msg = recv_msg

      case init_msg
      when LSProtocol::InitializeRequest
        init_result : LSProtocol::InitializeResult = controller.on_init(init_msg.params)

        response = LSProtocol::InitializeResponse.new(
          id: init_msg.id,
          result: init_result
        )

        send_msg(response)
        return true
      when LSProtocol::Request
        error_msg = LSProtocol::ResponseErrorMessage.new(
          id: init_msg.id,
          error: LSProtocol::ResponseError.new(
            code: LSProtocol::ErrorCodes::ServerNotInitialized.value,
            message: "Expecting an initialize request but received #{init_msg.method}."
          )
        )

        send_msg(error_msg)
      end
    rescue IO::Error
      return false
    rescue e : MessageError
      # Every request before the initialize one gets the same error,
      # while the initialize one gets its own
      answer_with_error(e, code: e.method == "initialize" ? e.code : LSProtocol::ErrorCodes::ServerNotInitialized)
    rescue e
      Log.error(exception: e) { e }
    end
  end

  # Returns once the input gets closed.
  def server_loop(controller : Larimar::Controller) : Nil
    loop do
      begin
        message = recv_msg
      rescue IO::Error
        return
      rescue e : MessageError
        answer_with_error(e)
        next
      rescue e
        # A malformed message shouldn't take the whole server down
        Log.error(exception: e) { e }
        next
      end

      dispatch(controller, message)
    end
  end

  # Keeps track of the messages dispatched about a document, each one
  # with a channel which gets closed once the message has been handled.
  private class DocumentQueue
    # The most recent text synchronization notification, closed once
    # handled, along with all the ones before it.
    property text_sync_done : Channel(Nil)?

    # The other messages dispatched since the most recent text synchronization notification.
    getter others_done = [] of Channel(Nil)

    # Returns `true` if every message dispatched so far has been handled.
    def idle? : Bool
      text_sync_done = self.text_sync_done
      return false if text_sync_done && !text_sync_done.closed?

      others_done.all?(&.closed?)
    end
  end

  # Messages dispatched so far, by the documents they're about.
  #
  # NOTE: Only ever accessed by the fiber calling `#dispatch`.
  @document_queues = Hash(URI, DocumentQueue).new

  # Messages dispatched so far that aren't about a document, each one
  # with a channel which gets closed once the message has been handled.
  #
  # NOTE: Only ever accessed by the fiber calling `#dispatch`.
  @others_done = [] of Channel(Nil)

  # Handles *message* using *controller* in a new fiber, without ever
  # blocking the caller, so that e.g. a `$/cancelRequest` can always get
  # through to a request blocking a pending edit. The `$/cancelRequest`
  # is applied before returning, so it's never about a later request.
  #
  # Messages see the documents as the client did when sending them:
  # text synchronization notifications are applied in the order they were
  # sent, once every message sent before them about the same document,
  # or no document at all, has been handled. Other messages wait for the
  # text synchronization notifications sent before them about the same
  # document, or about any document if they aren't about one, except
  # the ones that need to get through right away.
  def dispatch(controller : Larimar::Controller, message : LSProtocol::Message) : Nil
    if message.is_a?(LSProtocol::CancelNotification)
      # Cancelled right away, as once the request is answered the client
      # may reuse its id, and the cancellation must not reach the new one
      cancel_request(message.params.id)
      return
    end

    wait_for = [] of Channel(Nil)
    done = Channel(Nil).new unless urgent?(message)

    if done
      if (uri = document_uri(message))
        # Most of the queues of the closed documents are idle by the time
        # another document gets closed, so that's when they're dropped
        drop_idle_document_queues if message.is_a?(LSProtocol::DidCloseTextDocumentNotification)

        queue = @document_queues.put_if_absent(uri) { DocumentQueue.new }
        queue.text_sync_done.try { |text_sync_done| wait_for << text_sync_done }

        if text_sync?(message)
          wait_for.concat(queue.others_done)
          wait_for.concat(@others_done.reject!(&.closed?))
          queue.others_done.clear
          queue.text_sync_done = done
        else
          queue.others_done.reject!(&.closed?)
          queue.others_done << done
        end
      else
        drop_idle_document_queues
        @document_queues.each_value do |queue|
          queue.text_sync_done.try { |text_sync_done| wait_for << text_sync_done }
        end

        @others_done.reject!(&.closed?)
        @others_done << done
      end
    end

    if (request = message).is_a?(LSProtocol::Request)
      # Tracked right away, so that the request can get cancelled while waiting
      cancel_token = track_request(request.id)

      spawn_handler(wait_for, done) do
        handle_request(controller, request, cancel_token)
      end
    else
      spawn_handler(wait_for, done) do
        handle_message(controller, message)
      end
    end
  end

  # Answers the request *error* is about with it, if it's about one,
  # with the given error *code*.
  private def answer_with_error(error : MessageError, code : LSProtocol::ErrorCodes = error.code) : Nil
    if error.ignorable?
      Log.debug { error.message }
    else
      Log.warn { error.message }
    end

    error.response(code).try { |response| send_msg(response) }
  end

  # Drops the queues of the documents with no message left to handle,
  # which are as good as new ones.
  private def drop_idle_document_queues : Nil
    @document_queues.reject! { |_, queue| queue.idle? }
  end

  # Spawns a fiber waiting for every channel of *wait_for* to get closed,
  # then running the given block, closing *done* once it's finished.
  private def spawn_handler(wait_for : Array(Channel(Nil)), done : Channel(Nil)?, &block : ->) : Nil
    spawn do
      wait_for.each(&.receive?)
      block.call
    ensure
      done.try &.close
    end
  end

  # Returns the URI of the document *message* is about, if any.
  private def document_uri(message : LSProtocol::Message) : URI?
    return unless message.responds_to?(:params)
    return unless (params = message.params).responds_to?(:text_document)
    return unless (text_document = params.text_document).responds_to?(:uri)

    text_document.uri
  end

  # Returns `true` if *message* changes the contents of the documents.
  private def text_sync?(message : LSProtocol::Message) : Bool
    message.is_a?(LSProtocol::DidOpenTextDocumentNotification |
                  LSProtocol::DidChangeTextDocumentNotification |
                  LSProtocol::DidCloseTextDocumentNotification)
  end

  # Returns `true` if *message* needs to be handled right away,
  # not waiting for anything sent before it.
  private def urgent?(message : LSProtocol::Message) : Bool
    message.is_a?(LSProtocol::ShutdownRequest | LSProtocol::ExitNotification | ClientResponse)
  end

  # Cancellation sources of the requests not answered yet, by their ids
  @cancel_sources = Hash(Int32 | String, CancellationTokenSource).new
  @cancel_sources_mutex = Mutex.new

  # Registers the request *id* as pending, returning the token cancelling it.
  private def track_request(id : Int32 | String) : CancellationToken
    @cancel_sources_mutex.synchronize do
      (@cancel_sources[id] = CancellationTokenSource.new).token
    end
  end

  # Forgets about the request *id*, once handled.
  #
  # The *cancel_token* is the one returned by `#track_request` for it,
  # so that a newer request reusing the *id* (allowed once the response
  # got out) is left alone.
  private def untrack_request(id : Int32 | String, cancel_token : CancellationToken) : Nil
    @cancel_sources_mutex.synchronize do
      if @cancel_sources[id]?.try(&.token.same?(cancel_token))
        @cancel_sources.delete(id)
      end
    end
  end

  private def request_cancelled_response(id : Int32 | String) : LSProtocol::ResponseErrorMessage
    LSProtocol::ResponseErrorMessage.new(
      id: id,
      error: LSProtocol::ResponseError.new(
        code: LSProtocol::LSPErrorCodes::RequestCancelled.value,
        message: "Request cancelled."
      )
    )
  end

  # Cancels the request *id*, if it's still pending.
  private def cancel_request(id : Int32 | String) : Nil
    @cancel_sources_mutex.synchronize { @cancel_sources.delete(id) }
      .try(&.cancel)
  end

  # Handles the *request* using *controller*, answering it.
  #
  # The *cancel_token* is the one returned by `#track_request` for it.
  private def handle_request(controller : Larimar::Controller, request : LSProtocol::Request, cancel_token : CancellationToken) : Nil
    response =
      if cancel_token.cancelled?
        # Got cancelled before it could be handled
        request_cancelled_response(request.id)
      else
        case request
        when LSProtocol::ShutdownRequest
          # Sometimes the upstream may not send the exit notification,
          # leading to a zombie process being leftover even if the client is closed.
          # Shutdown after a while regardless
          if (delay = shutdown_exit_delay)
            spawn do
              sleep(delay)
              exit
            end
          end
          # Not using ShutdownResponse as it doesn't include the result
          nil
        else
          controller.on_request(request, cancel_token)
        end || LSProtocol::ResponseMessage.new(id: request.id, result: nil)
      end

    # Got cancelled while being handled, the client won't use the result anyway
    response = request_cancelled_response(request.id) if cancel_token.cancelled?

    send_msg(response)
  rescue e
    # Gave up as the request got cancelled
    if e.is_a?(CancellationException) && cancel_token.cancelled?
      send_msg(request_cancelled_response(request.id))
    else
      Log.error(exception: e) { "Error: #{e}\n#{e.backtrace.join("\n")}" }

      send_msg(LSProtocol::ResponseMessage.new(id: request.id, result: nil))
    end
  ensure
    untrack_request(request.id, cancel_token)
  end

  # Handles the *message*, other than a request, using *controller*.
  private def handle_message(controller : Larimar::Controller, message : LSProtocol::Message) : Nil
    case message
    when LSProtocol::ExitNotification
      exit
    when LSProtocol::InitializedNotification
      controller.when_ready
    when LSProtocol::Notification
      controller.on_notification(message)
    when ClientResponse
      controller.on_response(message)
    end
  rescue e
    Log.error(exception: e) { "Error: #{e}\n#{e.backtrace.join("\n")}" }
  end

  # Transmit methods

  # How many requests sent to the client, but not answered yet,
  # to remember the methods of, forgetting the oldest ones first
  OUTGOING_METHODS_LIMIT = 1024

  # Methods of the requests sent to the client not answered yet, by their ids,
  # as the responses don't include them, but parsing them needs them
  @outgoing_methods = Hash(Int32 | String, String).new
  @outgoing_methods_mutex = Mutex.new

  def send_msg(message : LSProtocol::Message, log : Bool = true) : Nil
    json = message.to_json

    if log
      Log.info &.emit("Sending message #{message.class}")
      Log.debug &.emit(json)
    end

    if message.is_a?(LSProtocol::Request)
      @outgoing_methods_mutex.synchronize do
        @outgoing_methods[message.id] = message.method

        # The client may never answer some, e.g. if they got cancelled
        @outgoing_methods.shift if @outgoing_methods.size > OUTGOING_METHODS_LIMIT
      end
    end

    @output_lock.synchronize do
      @output << "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
      @output.flush
    end
  end

  def recv_msg : LSProtocol::Message
    content_length = nil
    # content_type = DEFAULT_CONTENT_TYPE

    # Headers are terminated by an empty line, which must be consumed as well
    loop do
      header = @input.gets("\r\n", chomp: true)
      raise IO::EOFError.new if header.nil?
      break if header.empty?

      name, _, value = header.partition(':')

      # Header names are case-insensitive
      case name.strip.downcase
      when "content-length"
        content_length = value.strip.to_i
      when "content-type"
        # content_type = value.strip
      else
        Log.warn { "Ignoring unknown header #{name}" }
      end
    end

    if content_length.nil?
      raise "Content-Length is nil"
    end

    content_bytes = Bytes.new(content_length)

    if @input.read_fully?(content_bytes).nil?
      raise IO::EOFError.new("Content-Length #{content_length} does not match actual length")
    end

    content = String.new(content_bytes)

    message = parse_msg(content)

    Log.info &.emit("Received message #{message.class}")
    Log.debug &.emit(content)

    message
  end

  # Parses the JSON-RPC message *content*.
  #
  # Unlike `LSProtocol.parse_message`, it handles the responses to the
  # requests sent to the client, which come without a method: their
  # results get parsed as the ones of the methods of these requests,
  # if known, or as a `LSProtocol::ResponseMessage` otherwise.
  #
  # Raises `MessageError` for a message with an unknown method, or
  # whose contents don't match the ones expected for its method.
  def parse_msg(content : String) : LSProtocol::Message
    json = JSON.parse(content).as_h? || raise LSProtocol::ParseError.new("Expecting a JSON object")
    id = json["id"]?.try { |value| value.as_i? || value.as_s? }

    if (method = json["method"]?)
      unless (method_name = method.as_s?)
        raise MessageError.new(id, :invalid_request, "Expecting a string method, not #{method.to_json}")
      end

      unless (types = LSProtocol::METHOD_TO_TYPES[method_name]?)
        raise MessageError.new(id, :method_not_found, "Unknown method #{method_name}", method_name)
      end

      begin
        # Like `LSProtocol.parse_message` does, without parsing the JSON again
        return types[0].from_json(content).as(LSProtocol::Message)
      rescue e : JSON::ParseException
        raise MessageError.new(id, :invalid_params, "Invalid #{method_name} message: #{e.message}", method_name)
      end
    end

    request_method = id.try { |key| @outgoing_methods_mutex.synchronize { @outgoing_methods.delete(key) } }

    if json["error"]?.try(&.as_h?)
      LSProtocol::ResponseErrorMessage.from_json(content)
    elsif request_method && (types = LSProtocol::METHOD_TO_TYPES[request_method]?)
      types[1].from_json(content).as(LSProtocol::Message)
    else
      LSProtocol::ResponseMessage.from_json(content)
    end
  end
end
