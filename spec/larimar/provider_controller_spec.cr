require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

private class RecordingProvider < Larimar::Provider
  getter changed = [] of Larimar::TextDocument
  getter saved = [] of Larimar::TextDocument

  def on_change(document : Larimar::TextDocument) : Nil
    @changed << document
  end

  def on_save(document : Larimar::TextDocument) : Nil
    @saved << document
  end
end

private def notification(method, params)
  LSProtocol.parse_message({
    jsonrpc: "2.0",
    method:  method,
    params:  params,
  }.to_json).as(LSProtocol::Notification)
end

private def open_notification
  notification("textDocument/didOpen", {
    textDocument: {uri: URI_STRING, languageId: "crystal", version: 1, text: ""},
  })
end

private def change_notification
  notification("textDocument/didChange", {
    textDocument:   {uri: URI_STRING, version: 2},
    contentChanges: [{text: "foo"}],
  })
end

private def save_notification
  notification("textDocument/didSave", {
    textDocument: {uri: URI_STRING},
  })
end

private def close_notification
  notification("textDocument/didClose", {
    textDocument: {uri: URI_STRING},
  })
end

private def new_controller(provider)
  Larimar::ProviderController.new.tap do |controller|
    controller.server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)
    controller.register_provider(provider)
  end
end

# Handles *message* in another fiber, while the document is being closed,
# like when it's waiting for the lock of the document taken by `didClose`.
private def handle_while_closing(controller, message)
  document = controller.@documents[URI.parse(URI_STRING)]
  done = Channel(Nil).new

  document.mutex.synchronize do
    spawn do
      controller.on_notification(message)
      done.send(nil)
    end
    # Lets the spawned fiber reach the lock of the document
    sleep 10.milliseconds

    controller.on_notification(close_notification)
  end

  done.receive
end

describe Larimar::ProviderController do
  it "passes changed and saved documents to the providers" do
    provider = RecordingProvider.new
    controller = new_controller(provider)

    controller.on_notification(open_notification)
    controller.on_notification(change_notification)
    controller.on_notification(save_notification)

    provider.changed.size.should eq(1)
    provider.saved.size.should eq(1)
  end

  it "doesn't pass a document changed while getting closed to the providers" do
    provider = RecordingProvider.new
    controller = new_controller(provider)

    controller.on_notification(open_notification)
    handle_while_closing(controller, change_notification)

    provider.changed.should be_empty
  end

  it "doesn't pass a document saved while getting closed to the providers" do
    provider = RecordingProvider.new
    controller = new_controller(provider)

    controller.on_notification(open_notification)
    handle_while_closing(controller, save_notification)

    provider.saved.should be_empty
  end
end
