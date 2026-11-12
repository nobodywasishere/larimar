require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

private def notification(method, params)
  LSProtocol.parse_message({
    jsonrpc: "2.0",
    method:  method,
    params:  params,
  }.to_json)
end

private def open_notification(text = "")
  notification("textDocument/didOpen", {
    textDocument: {uri: URI_STRING, languageId: "crystal", version: 1, text: text},
  }).as(LSProtocol::DidOpenTextDocumentNotification)
end

private def close_notification
  notification("textDocument/didClose", {
    textDocument: {uri: URI_STRING},
  }).as(LSProtocol::DidCloseTextDocumentNotification)
end

private def new_controller
  Larimar::ProviderController.new.tap do |controller|
    controller.server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)
  end
end

describe Larimar::ProviderController do
  describe "#document?" do
    it "returns the document once opened, and nil once closed" do
      controller = new_controller
      uri = URI.parse(URI_STRING)

      controller.document?(uri).should be_nil

      controller.on_notification(open_notification)
      controller.document?(uri).should_not be_nil

      controller.on_notification(close_notification)
      controller.document?(uri).should be_nil
    end
  end
end
