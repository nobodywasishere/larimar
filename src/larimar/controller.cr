class Larimar::Controller
  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::ServerCapabilities?
  end

  def when_ready
  end

  def on_request(message)
    case message
    when LSProtocol::TextDocumentFormattingRequest
      file_path = URI.parse(message.params.text_document.uri).path

      return
    else
    end

    Log.error { "Unhandled message #{message.class.to_s.split("::").last}" }
  end

  def on_notification(message)
    Log.error { "Unhandled message #{message.class.to_s.split("::").last}" }
  end

  def on_response(message)
    Log.error { "Unhandled message #{message.class.to_s.split("::").last}" }
  end
end
