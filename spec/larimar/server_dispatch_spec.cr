require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

private class RecordingController < Larimar::Controller
  @messages = [] of LSProtocol::Message
  @messages_mutex = Mutex.new

  # Handling of a `didChange` waits for this channel to get closed
  getter change_gate = Channel(Nil).new

  # Handling of a request waits for this channel to get closed
  getter request_gate = Channel(Nil).new

  # Version of the `didChange` that's slow to handle
  property slow_change_version : Int32?

  def initialize(gated : Bool = false, gated_requests : Bool = false)
    change_gate.close unless gated
    request_gate.close unless gated_requests
  end

  # Returns the messages handled so far, in the order they were handled
  def messages : Array(LSProtocol::Message)
    @messages_mutex.synchronize { @messages.dup }
  end

  def on_init(init_params) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)
  end

  def on_request(message, cancel_token) : LSProtocol::Message?
    request_gate.receive?
    record(message)
    nil
  end

  def on_notification(message : LSProtocol::DidChangeTextDocumentNotification) : Nil
    change_gate.receive?
    sleep 10.milliseconds if message.params.text_document.version == slow_change_version
    record(message)
  end

  def on_notification(message) : Nil
    record(message)
  end

  private def record(message) : Nil
    @messages_mutex.synchronize { @messages << message }
  end
end

private class SlowDefinitionProvider < Larimar::Provider
  include Larimar::DefinitionProvider

  getter started = Channel(Nil).new
  getter? cancelled = false

  def provide_definition(document, position, token) : LSProtocol::DefinitionResult?
    started.send(nil)

    deadline = Time.instant + 1.second
    until !!token.try(&.cancelled?) || Time.instant >= deadline
      sleep 1.millisecond
    end
    @cancelled = !!token.try(&.cancelled?)

    nil
  end
end

private def message(payload)
  LSProtocol.parse_message(payload.to_json)
end

private def notification(method, params)
  message({jsonrpc: "2.0", method: method, params: params})
end

private def open_notification
  notification("textDocument/didOpen", {
    textDocument: {uri: URI_STRING, languageId: "crystal", version: 1, text: ""},
  })
end

private def change_notification(version)
  notification("textDocument/didChange", {
    textDocument:   {uri: URI_STRING, version: version},
    contentChanges: [{text: "v#{version}"}],
  })
end

private def close_notification
  notification("textDocument/didClose", {
    textDocument: {uri: URI_STRING},
  })
end

private def save_notification
  notification("textDocument/didSave", {
    textDocument: {uri: URI_STRING},
  })
end

private def cancel_notification(id)
  notification("$/cancelRequest", {id: id})
end

private def definition_request(id)
  message({
    jsonrpc: "2.0",
    id:      id,
    method:  "textDocument/definition",
    params:  {
      textDocument: {uri: URI_STRING},
      position:     {line: 0, character: 0},
    },
  })
end

private def new_server
  Larimar::Server.new(IO::Memory.new, IO::Memory.new)
end

private def wait_until(timeout = 1.second, &)
  deadline = Time.instant + timeout
  until yield
    fail "Timed out waiting for the condition" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe Larimar::Server do
  describe "#dispatch" do
    it "handles text synchronization notifications in the order they were sent" do
      controller = RecordingController.new
      controller.slow_change_version = 2
      server = new_server

      messages = [
        open_notification,
        change_notification(2),
        change_notification(3),
        close_notification,
      ]
      messages.each { |message| server.dispatch(controller, message) }

      wait_until { controller.messages.size == messages.size }
      controller.messages.should eq(messages)
    end

    it "handles messages in another fiber" do
      controller = RecordingController.new
      server = new_server

      message = save_notification
      server.dispatch(controller, message)
      controller.messages.should be_empty

      wait_until { controller.messages == [message] }
    end

    it "handles other messages after the text synchronization notifications sent before them" do
      controller = RecordingController.new(gated: true)
      server = new_server

      change = change_notification(2)
      save = save_notification
      request = definition_request(1)

      spawn do
        server.dispatch(controller, change)
        server.dispatch(controller, save)
        server.dispatch(controller, request)
      end

      sleep 20.milliseconds
      controller.messages.should be_empty

      controller.change_gate.close
      wait_until { controller.messages.size == 3 }
      controller.messages.first.should eq(change)
      controller.messages.should contain(save)
      controller.messages.should contain(request)
    end

    it "doesn't block the caller while a text synchronization notification is pending" do
      controller = RecordingController.new(gated: true)
      server = new_server

      dispatched = Atomic(Bool).new(false)

      # Dispatching from another fiber, so that the spec fails instead of
      # blocking forever, should the notification be handled by the caller
      spawn do
        server.dispatch(controller, change_notification(2))
        server.dispatch(controller, change_notification(3))
        server.dispatch(controller, save_notification)
        dispatched.set(true)
      end

      wait_until { dispatched.get }
      controller.messages.should be_empty
      controller.change_gate.close
    end

    it "handles text synchronization notifications after the messages sent before them" do
      controller = RecordingController.new(gated_requests: true)
      server = new_server

      request = definition_request(1)
      save = save_notification
      change = change_notification(2)

      server.dispatch(controller, request)
      server.dispatch(controller, save)
      server.dispatch(controller, change)

      wait_until { controller.messages == [save] }
      sleep 20.milliseconds
      controller.messages.should eq([save])

      controller.request_gate.close
      wait_until { controller.messages.size == 3 }
      controller.messages.should eq([save, request, change])
    end

    it "answers a request cancelled while waiting for an edit, without handling it" do
      controller = RecordingController.new(gated: true)
      server = new_server

      change = change_notification(2)

      server.dispatch(controller, change)
      server.dispatch(controller, definition_request(1))
      server.dispatch(controller, cancel_notification(1))

      # Lets the cancellation get handled while the edit is pending
      sleep 20.milliseconds

      controller.change_gate.close
      wait_until { server.output.to_s.includes?(%("id":1)) }

      server.output.to_s.should contain(%("code":-32800))
      controller.messages.should eq([change])
    end

    it "lets a request get cancelled while an edit waits for it" do
      server = new_server
      controller = Larimar::ProviderController.new
      controller.server = server
      provider = SlowDefinitionProvider.new
      controller.register_provider(provider)

      server.dispatch(controller, open_notification)
      server.dispatch(controller, definition_request(1))
      provider.started.receive

      # Waits for the request to release the document
      server.dispatch(controller, change_notification(2))
      server.dispatch(controller, cancel_notification(1))

      wait_until { provider.cancelled? }
    end
  end
end
