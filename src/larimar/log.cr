class Larimar::LogBackend < ::Log::IOBackend
  def initialize(@server : Larimar::Server, formatter = LogFormatter)
    super(server.output, formatter: formatter)
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
    log_message = LSProtocol::LogMessageNotification.new(
      params: LSProtocol::LogMessageParams.new(type: message_type, message: format(entry)),
    )
    @server.send_msg(log_message, log: false)
  end

  def format(entry : ::Log::Entry) : String
    io = IO::Memory.new
    @formatter.format(entry, io)
    io.to_s
  end
end

::Log.define_formatter Larimar::LogFormatter, "#{source}: #{message}"
