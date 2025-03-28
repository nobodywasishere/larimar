class Larimar::Server
  Log = ::Larimar::Log.for(self)

  DEFAULT_CONTENT_TYPE = "application/vscode-jsonrpc; charset=utf-8"

  getter input : IO
  getter output : IO
  @output_lock = Mutex.new(:reentrant)

  def initialize(@input : IO, @output : IO)
  end

  def start(controller : Larimar::Controller)
    controller.server = self

    Log.info { "Starting server..." }

    handshake(controller)

    Log.info { "Connected successfully." }

    server_loop(controller)
  end

  def handshake(controller : Larimar::Controller)
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
        break
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
      exit(1)
    rescue e
      Log.error(exception: e) { e }
    end
  end

  def server_loop(controller : Larimar::Controller)
    loop do
      message = recv_msg

      spawn do
        response : LSProtocol::Message?
        nil_response = LSProtocol::ResponseMessage.new(id: message.id || "null", result: nil)

        case message
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
          response = controller.when_ready
        when LSProtocol::Request
          response = controller.on_request(message)
        when LSProtocol::Notification
          response = controller.on_notification(message)
        when LSProtocol::Response
          response = controller.on_response(message)
        end

        send_msg(response || nil_response)
      rescue e
        Log.error(exception: e) { "Error: #{e}\n#{e.backtrace.join("\n")}" }

        if message.is_a? LSProtocol::Request
          response = LSProtocol::ResponseMessage.new(id: message.id, result: nil)

          send_msg(response)
        end
      end
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

    message = LSProtocol.parse_message(content)

    Log.info &.emit("Received message #{message.class}")
    Log.debug &.emit(message.to_json)

    message
  end
end
