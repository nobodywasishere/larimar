abstract class Larimar::Controller
  Log = ::Larimar::Log.for(self)

  property! server : Larimar::Server

  abstract def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult

  def when_ready
  end

  # Requests

  # Handles the request *message*, returning the response to it, if any.
  #
  # Returning `nil` answers the request with a `null` result.
  #
  # The *cancel_token* gets cancelled once the client cancels the request.
  def on_request(message : LSProtocol::Request, cancel_token : CancellationToken) : LSProtocol::Message?
    Log.error { "Unhandled request message #{message.class.to_s.split("::").last}" }
    nil
  end

  # Notifications

  def on_notification(message : LSProtocol::Notification) : Nil
    Log.error { "Unhandled notification message #{message.class.to_s.split("::").last}" }
  end

  # Responses

  # Handles the *message* answering a request sent to the client.
  def on_response(message : ClientResponse) : Nil
    Log.error { "Unhandled response message #{message.class.to_s.split("::").last}" }
  end
end
