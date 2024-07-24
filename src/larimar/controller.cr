class Larimar::Controller
  Log = ::Larimar::Log.for(self)

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new

  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::ServerCapabilities?
  end

  def when_ready
  end

  def on_request(message)
    case message
    when LSProtocol::TextDocumentFormattingRequest
      @pending_requests << message.id

      file_path = URI.parse(message.params.text_document.uri).path

      return
    else
      Log.error { "Unhandled message #{message.class.to_s.split("::").last}" }
    end
  ensure
    @pending_requests.delete(message.id)
  end

  def on_notification(message)
    case message
    when LSProtocol::TextDocumentDidOpenNotification
    else
      Log.error { "Unhandled message #{message.class.to_s.split("::").last}" }
    end
  end

  def on_response(message)
    case message
    when Nil
    else
      Log.error { "Unhandled message #{message.class.to_s.split("::").last}" }
    end
  end
end
