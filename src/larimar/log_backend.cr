class Larimar::LogBackend < ::Log::IOBackend
  def initialize(@server : Larimar::Server)
    super(server.output)
  end

  def write(entry : ::Log::Entry)
    message_type = case entry.severity
                   when ::Log::Severity::Info
                     LSProtocol::MessageType::Info
                   when ::Log::Severity::Debug
                     LSProtocol::MessageType::Debug
                   when ::Log::Severity::Warn
                     LSProtocol::MessageType::Warning
                   when ::Log::Severity::Error, ::Log::Severity::Fatal
                     LSProtocol::MessageType::Error
                   else
                     LSProtocol::MessageType::Log
                   end
    log_message = LSProtocol::WindowLogMessageNotification.new(
      params: LSProtocol::LogMessageParams.new(type: message_type, message: entry.message),
    )
    @server.send_msg(log_message, log: false)
  end
end
