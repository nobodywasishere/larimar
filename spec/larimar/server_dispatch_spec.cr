require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

private class RecordingController < Larimar::Controller
  @messages = [] of LSProtocol::Message
  @messages_mutex = Mutex.new

  # Handling of a `didChange` waits for this channel to get closed
  getter change_gate = Channel(Nil).new

  # Handling of a request waits for this channel to get closed
  getter request_gate = Channel(Nil).new

  # Receives a value once handling of a request started
  getter request_started = Channel(Nil).new(1)

  # Version of the `didChange` that's slow to handle
  property slow_change_version : Int32?

  # Whether handling of a cancelled request raises `CancellationException`
  property? raise_when_cancelled = false

  # Whether handling of a request raises `CancellationException`, cancelled or not
  property? raise_cancellation = false

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
    select
    when request_started.send(nil)
    else
    end
    request_gate.receive?
    cancel_token.cancelled! if raise_when_cancelled?
    raise CancellationException.new if raise_cancellation?
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

# Output pausing on the first flush, until `resume` gets closed
private class DelayedFlush < IO::Memory
  # Receives a value once the output got paused
  getter flushed = Channel(Nil).new(1)

  # Flushing waits for this channel to get closed
  getter resume = Channel(Nil).new

  def flush
    unless resume.closed?
      flushed.send(nil)
      resume.receive?
    end
    super
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

private def change_notification(version, uri = URI_STRING)
  notification("textDocument/didChange", {
    textDocument:   {uri: uri, version: version},
    contentChanges: [{text: "v#{version}"}],
  })
end

private def close_notification
  notification("textDocument/didClose", {
    textDocument: {uri: URI_STRING},
  })
end

private def save_notification(uri = URI_STRING)
  notification("textDocument/didSave", {
    textDocument: {uri: uri},
  })
end

# A request which isn't about any document
private def workspace_symbol_request(id)
  message({
    jsonrpc: "2.0",
    id:      id,
    method:  "workspace/symbol",
    params:  {query: ""},
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
  Larimar::Server.new(IO::Memory.new, IO::Memory.new).tap do |server|
    # Exiting would end the spec run
    server.shutdown_exit_delay = nil
  end
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

    it "doesn't have messages wait for the edits of other documents" do
      controller = RecordingController.new(gated: true)
      server = new_server

      save = save_notification("file:///nonexistent/other.cr")

      server.dispatch(controller, change_notification(2))
      server.dispatch(controller, save)

      wait_until { controller.messages == [save] }
      controller.change_gate.close
    end

    it "has messages about no document wait for the edits of every document" do
      controller = RecordingController.new(gated: true)
      server = new_server

      change = change_notification(2, "file:///nonexistent/other.cr")
      request = workspace_symbol_request(1)

      server.dispatch(controller, change)
      server.dispatch(controller, request)

      sleep 20.milliseconds
      controller.messages.should be_empty

      controller.change_gate.close
      wait_until { controller.messages.size == 2 }
      controller.messages.should eq([change, request])
    end

    it "has edits wait for the messages about no document sent before them" do
      controller = RecordingController.new(gated_requests: true)
      server = new_server

      request = workspace_symbol_request(1)
      change = change_notification(2)

      server.dispatch(controller, request)
      server.dispatch(controller, change)

      sleep 20.milliseconds
      controller.messages.should be_empty

      controller.request_gate.close
      wait_until { controller.messages.size == 2 }
      controller.messages.should eq([request, change])
    end

    it "forgets about the documents once closed" do
      controller = RecordingController.new
      server = new_server

      other_uri = "file:///nonexistent/other.cr"

      server.dispatch(controller, open_notification)
      server.dispatch(controller, close_notification)
      wait_until { controller.messages.size == 2 }

      server.dispatch(controller, change_notification(2, other_uri))
      server.dispatch(controller, notification("textDocument/didClose", {
        textDocument: {uri: other_uri},
      }))

      server.@document_queues.keys.should eq([URI.parse(other_uri)])
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
      wait_until { server.output.to_s.includes?(%("id":1)) }
      server.output.to_s.should contain(%("code":-32800))
    end

    it "answers a request raising once cancelled while being handled with `RequestCancelled`" do
      controller = RecordingController.new(gated_requests: true)
      controller.raise_when_cancelled = true
      server = new_server

      server.dispatch(controller, workspace_symbol_request(1))
      controller.request_started.receive
      server.dispatch(controller, cancel_notification(1))

      # Lets the cancellation get handled while the request is being handled
      sleep 20.milliseconds
      controller.request_gate.close

      wait_until { server.output.to_s.includes?(%("id":1)) }
      server.output.to_s.should contain(%("code":-32800))
      controller.messages.should be_empty
    end

    it "doesn't answer a request raising `CancellationException` uncancelled with `RequestCancelled`" do
      controller = RecordingController.new
      controller.raise_cancellation = true
      server = new_server

      server.dispatch(controller, workspace_symbol_request(1))

      wait_until { server.output.to_s.includes?(%("id":1)) }
      server.output.to_s.should_not contain(%("code":-32800))
      server.output.to_s.should contain(%("result":null))
    end

    it "keeps a reused request ID cancellable after the old flush completes" do
      output = DelayedFlush.new
      server = Larimar::Server.new(IO::Memory.new, output)
      controller = RecordingController.new(gated_requests: true)

      server.dispatch(RecordingController.new, workspace_symbol_request(1))
      # The response is out, yet the handler of the request didn't finish
      output.flushed.receive
      output.to_s.should contain(%("id":1))

      # The client is free to reuse the ID once it got the response
      server.dispatch(controller, workspace_symbol_request(1))
      controller.request_started.receive
      output.resume.close
      # Lets the handler of the first request finish
      sleep 10.milliseconds
      server.dispatch(controller, cancel_notification(1))
      # Lets the cancellation get handled while the request is being handled
      sleep 10.milliseconds
      controller.request_gate.close

      wait_until { output.to_s.scan(%("id":1)).size == 2 }
      output.to_s.should contain(%("code":-32800))
    ensure
      output.try(&.resume.close)
      controller.try(&.request_gate.close)
    end

    it "answers shutdown while an edit is blocked" do
      controller = RecordingController.new(gated: true)
      server = new_server

      server.dispatch(controller, change_notification(2))
      server.dispatch(controller, message({
        jsonrpc: "2.0",
        id:      99,
        method:  "shutdown",
      }))

      wait_until(100.milliseconds) do
        server.output.to_s.includes?(%("id":99))
      end
    ensure
      controller.try(&.change_gate.close)
    end
  end
end
