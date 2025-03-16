abstract class Larimar::Controller
  Log = ::Larimar::Log.for(self)

  property! server : Larimar::Server

  abstract def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult

  def when_ready
  end

  # Requests

  def on_request(message : LSProtocol::Request) : Nil
    Log.error { "Unhandled request message #{message.class.to_s.split("::").last}" }
  end

  # Notifications

  def on_notification(message : LSProtocol::Notification) : Nil
    Log.error { "Unhandled notification message #{message.class.to_s.split("::").last}" }
  end

  # Responses

  def on_response(message : LSProtocol::Response) : Nil
    Log.error { "Unhandled response message #{message.class.to_s.split("::").last}" }
  end
end
