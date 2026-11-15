require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

private class RecordingController < Larimar::Controller
  getter notifications = [] of LSProtocol::Notification

  def on_init(init_params) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)
  end

  def on_notification(message) : Nil
    @notifications << message
  end
end

private def notification(method, params)
  LSProtocol.parse_message({
    jsonrpc: "2.0",
    method:  method,
    params:  params,
  }.to_json).as(LSProtocol::Notification)
end

private def change_notification(version)
  notification("textDocument/didChange", {
    textDocument:   {uri: URI_STRING, version: version},
    contentChanges: [{text: "v#{version}"}],
  })
end

private def new_server
  Larimar::Server.new(IO::Memory.new, IO::Memory.new)
end

describe Larimar::Server do
  describe "#dispatch" do
    it "handles text synchronization notifications right away, in order" do
      controller = RecordingController.new
      server = new_server

      messages = [
        notification("textDocument/didOpen", {
          textDocument: {uri: URI_STRING, languageId: "crystal", version: 1, text: ""},
        }),
        change_notification(2),
        change_notification(3),
        notification("textDocument/didClose", {
          textDocument: {uri: URI_STRING},
        }),
      ]
      messages.each { |message| server.dispatch(controller, message) }

      # No fiber got a chance to run in the meantime
      controller.notifications.should eq(messages)
    end

    it "handles other notifications in another fiber" do
      controller = RecordingController.new
      server = new_server

      message = notification("textDocument/didSave", {
        textDocument: {uri: URI_STRING},
      })
      server.dispatch(controller, message)
      controller.notifications.should be_empty

      Fiber.yield
      controller.notifications.should eq([message])
    end
  end
end
