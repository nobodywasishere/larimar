class Larimar::Server
  Log = ::Larimar::Log.for(self)

  DEFAULT_CONTENT_TYPE = "application/vscode-jsonrpc; charset=utf-8"

  getter input : IO
  getter output : IO
  @output_lock = Mutex.new(:reentrant)

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
      rescue e
        # A malformed message shouldn't take the whole server down
        Log.error(exception: e) { e }
        next
      end

      dispatch(controller, message)
    end
  end

  # Closed once the most recently dispatched text synchronization
  # notification has been handled, along with all the ones before it.
  #
  # NOTE: Only ever accessed by the fiber calling `#dispatch`.
  @text_sync_done : Channel(Nil)?

  # Handles *message* using *controller* in a new fiber, without ever
  # blocking the caller, so that e.g. a `$/cancelRequest` can always get
  # through to a request blocking a pending edit.
  #
  # Text synchronization notifications are applied to the documents
  # in the order they were sent, each one waiting for the previous one.
  # Other messages wait for the text synchronization notifications sent
  # before them too, so that they see the documents as the client did,
  # except the ones that need to get through right away.
  def dispatch(controller : Larimar::Controller, message : LSProtocol::Message) : Nil
    wait_for = @text_sync_done unless urgent?(message)
    done = @text_sync_done = Channel(Nil).new if text_sync?(message)

    # Tracked right away, so that the request can get cancelled while waiting
    cancel_token = track_request(message.id) if message.is_a?(LSProtocol::Request)

    spawn do
      wait_for.try &.receive?
      handle_message(controller, message, cancel_token)
    ensure
      done.try &.close
    end
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
    message.is_a?(LSProtocol::CancelNotification |
                  LSProtocol::ExitNotification |
                  LSProtocol::Response)
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
  private def untrack_request(id : Int32 | String) : Nil
    @cancel_sources_mutex.synchronize { @cancel_sources.delete(id) }
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

  private def handle_message(controller : Larimar::Controller, message : LSProtocol::Message, cancel_token : CancellationToken? = nil) : Nil
    response : LSProtocol::Message?
    if (message_id = message.id)
      nil_response = LSProtocol::ResponseMessage.new(id: message_id, result: nil)
    end

    case message
    when LSProtocol::CancelNotification
      cancel_request(message.params.id)
    when LSProtocol::ExitNotification
      exit
    when LSProtocol::ShutdownRequest
      # Not using ShutdownResponse as it doesn't include the result
      response = LSProtocol::ResponseMessage.new(id: message.id, result: nil)

      # Sometimes the upstream may not send the exit notification,
      # leading to a zombie process being leftover even if the client is closed.
      # Shutdown after 3 seconds regardless
      spawn do
        sleep(3.seconds)
        exit
      end
    when LSProtocol::InitializedNotification
      controller.when_ready
    when LSProtocol::Request
      begin
        cancel_token ||= track_request(message.id)

        response =
          if cancel_token.cancelled?
            # Got cancelled before it could be handled
            request_cancelled_response(message.id)
          else
            controller.on_request(message, cancel_token) || nil_response
          end
      ensure
        untrack_request(message.id)
      end

      if response.nil?
        Log.error { "Error: No response for #{message.class}" }
      end
    when LSProtocol::Notification
      controller.on_notification(message)
    when LSProtocol::Response
      controller.on_response(message)
    end

    if response
      send_msg(response)
    end
  rescue e
    Log.error(exception: e) { "Error: #{e}\n#{e.backtrace.join("\n")}" }

    if message.is_a? LSProtocol::Request
      response = LSProtocol::ResponseMessage.new(id: message.id, result: nil)

      send_msg(response)
    end
  end

  # Transmit methods

  def send_msg(message : LSProtocol::Message, log : Bool = true) : Nil
    if log
      Log.info &.emit("Sending message #{message.class}")
      Log.debug &.emit(message.to_json)
    end

    json = message.to_json

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

    message = LSProtocol.parse_message(content)

    Log.info &.emit("Received message #{message.class}")
    Log.debug &.emit(message.to_json)

    message
  end
end
