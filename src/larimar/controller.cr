abstract class Larimar::Controller
  Log = ::Larimar::Log.for(self)

  property! server : Larimar::Server

  abstract def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult

  def when_ready
  end

  # Requests

  # Handles the request *message*, returning the response to it, if any.
  #
  # Returning `nil` answers the request with a `null` result, while
  # raising answers it with an error, a `MethodNotFound` one for the
  # unhandled requests.
  #
  # The *cancel_token* gets cancelled once the client cancels the request.
  def on_request(message : LSProtocol::Request, cancel_token : CancellationToken) : LSProtocol::Message?
    raise Server::MessageError.new(
      message.id, :method_not_found,
      "Unhandled request message #{message.class.to_s.split("::").last}",
      message.method
    )
  end

  # Notifications

  # Handles the notification *message*.
  #
  # The unhandled ones are only logged, as debug ones if they may be
  # ignored (see `Larimar.ignorable_notification?`), as warnings otherwise.
  def on_notification(message : LSProtocol::Notification) : Nil
    if Larimar.ignorable_notification?(message.method)
      Log.debug { "Unhandled notification message #{message.class.to_s.split("::").last}" }
    else
      Log.warn { "Unhandled notification message #{message.class.to_s.split("::").last}" }
    end
  end

  # Responses

  # Handles the *message* answering a request sent to the client.
  def on_response(message : ClientResponse) : Nil
    Log.error { "Unhandled response message #{message.class.to_s.split("::").last}" }
  end
end
