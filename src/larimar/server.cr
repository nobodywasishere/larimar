class Larimar::Server
  Log = ::Larimar::Log.for(self)

  DEFAULT_CONTENT_TYPE        = "application/vscode-jsonrpc; charset=utf-8"
  DEFAULT_SERVER_CAPABILITIES = LSProtocol::ServerCapabilities.new(
    text_document_sync: LSProtocol::TextDocumentSyncKind::Incremental,
    document_formatting_provider: true,
    # document_range_formatting_provider: true,
    # completion_provider: LSProtocol::CompletionOptions.new(
    #   trigger_characters: [".", ":", "@"]
    # ),
    # hover_provider: true,
    # definition_provider: true,
    # document_symbol_provider: true,
    # inlay_hint_provider: true
  )

  getter input : IO
  getter output : IO

  def initialize(
    @input : IO, @output : IO,
    @server_capabilities : LSProtocol::ServerCapabilities = DEFAULT_SERVER_CAPABILITIES
  )
    @output_lock = Mutex.new(:reentrant)
  end

  def start(controller : Larimar::Controller)
    Log.info { "Starting server..." }
    handshake(controller)

    begin
      controller.when_ready
    rescue exc
      Log.error(exception: exc) { "Error during initialization: #{exc}" }
      return
    end

    Log.info { "Connected successfully." }
    server_loop(controller)
  end

  def handshake(controller : Larimar::Controller)
    loop do
      init_msg = recv_msg

      case init_msg
      when LSProtocol::InitializeRequest
        init_result : LSProtocol::InitializeResult = controller.on_init(init_msg.params.capabilities) ||
          LSProtocol::InitializeResult.new(@server_capabilities)

        reply(init_msg, result: init_result)

        break
      when LSProtocol::Request
        # TODO: send error
        reply(init_msg, error: LSProtocol::ResponseError.new(
          code: LSProtocol::ErrorCodes::ServerNotInitialized.value,
          message: "Expecting an initialize request but received #{init_msg.method}."
        ))
      end
    rescue IO::Error
      exit(1)
    rescue e
      Log.error(exception: e) { e }
    end
  end

  def server_loop(controller : Larimar::Controller)
    loop do
      message = recv_msg
      Log.info &.emit("Received message #{message.class}\n  #{message.to_json}")

      case message
      when LSProtocol::ExitNotification
        exit(0)
      when LSProtocol::ShutdownRequest
        reply(request: message, result: nil)
      when LSProtocol::Request
        result = controller.on_request(message)
        reply(request: message, result: result)
      when LSProtocol::Response
        result = controller.on_notification(message)
        reply(request: message, result: result)
      when LSProtocol::Notification
        result = controller.on_response(message)
        reply(request: message, result: result)
      end
    rescue e
      Log.error(exception: e) { e }
      if message.is_a? LSProtocol::Request
        reply(request: message, result: nil)
      end
    end
  end

  # Transmit methods

  def send_msg(message : LSProtocol::Message, log : Bool = true) : Nil
    json = message.to_json

    @output_lock.synchronize {
      @output << "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
      @output.flush
    }
  end

  def recv_msg : LSProtocol::Message
    content_length = nil
    content_type = DEFAULT_CONTENT_TYPE

    2.times do
      header = @input.gets("\r\n", chomp: true)
      break if header.nil? || header.empty?

      name, value = header.split(":")
      case name
      when "Content-Length"
        content_length = value.to_i
      when "Content-Type"
        content_type = value
      else
        raise "Unknown header #{name}"
      end
    end

    if content_length.nil?
      raise "Content-Length is nil"
    end

    content_bytes = Bytes.new(content_length)

    if @input.read_fully?(content_bytes).nil?
      raise "Content-Length #{content_length} does not match actual length"
    end

    content = String.new(content_bytes)

    LSProtocol.parse_message(content)
  end

  def reply(request : LSProtocol::Message, result = nil, error : LSProtocol::ResponseError? = nil)
    if error
      response_msg = LSProtocol::ResponseErrorMessage.new(id: request.id || "null", error: error)
    else
      response_msg = LSProtocol::ResponseMessage.new(id: request.id || "null", result: JSON.parse(result.to_json))
    end

    send_msg(response_msg)
  end
end
