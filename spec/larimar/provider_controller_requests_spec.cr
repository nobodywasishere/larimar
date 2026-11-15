require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

# Cancels the request it's handling, recording whether its token got cancelled.
private class CancellingProvider < Larimar::Provider
  include Larimar::DefinitionProvider

  property request_id : Int32 | String = 0
  getter? cancelled = false

  def provide_definition(document, position, token) : LSProtocol::DefinitionResult?
    controller.on_notification(
      LSProtocol.parse_message({
        jsonrpc: "2.0",
        method:  "$/cancelRequest",
        params:  {id: request_id},
      }.to_json).as(LSProtocol::CancelNotification)
    )
    @cancelled = token.try(&.cancelled?) || false

    nil
  end
end

private def message(payload)
  LSProtocol.parse_message(payload.to_json)
end

private def definition_request(id, uri = URI_STRING)
  message({
    jsonrpc: "2.0",
    id:      id,
    method:  "textDocument/definition",
    params:  {textDocument: {uri: uri}, position: {line: 0, character: 0}},
  }).as(LSProtocol::DefinitionRequest)
end

private def new_controller(*providers)
  Larimar::ProviderController.new.tap do |controller|
    controller.server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)
    providers.each { |provider| controller.register_provider(provider) }

    controller.on_notification(
      message({
        jsonrpc: "2.0",
        method:  "textDocument/didOpen",
        params:  {
          textDocument: {uri: URI_STRING, languageId: "crystal", version: 1, text: ""},
        },
      }).as(LSProtocol::DidOpenTextDocumentNotification)
    )
  end
end

describe Larimar::ProviderController do
  describe "#on_request" do
    it "forgets about a request once handled" do
      controller = new_controller

      controller.on_request(definition_request(1)).should_not be_nil
      controller.@cancel_tokens.should be_empty
    end

    it "forgets about a request for a document that isn't open" do
      controller = new_controller

      controller.on_request(definition_request(1, "file:///nonexistent/other.cr")).should be_nil
      controller.@cancel_tokens.should be_empty
    end

    it "cancels a request while it's being handled" do
      provider = CancellingProvider.new
      provider.request_id = "request"
      controller = new_controller(provider)

      controller.on_request(definition_request("request"))

      provider.cancelled?.should be_true
      controller.@cancel_tokens.should be_empty
    end
  end
end
