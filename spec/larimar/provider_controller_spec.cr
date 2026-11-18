require "../spec_helper"

private URI_STRING = "file:///nonexistent/spec_subject.cr"

private class RecordingProvider < Larimar::Provider
  getter changed = [] of Larimar::TextDocument
  getter saved = [] of Larimar::TextDocument

  # Closing a document waits for this channel to get closed
  getter close_gate = Channel(Nil).new

  # Receives a value once closing a document started
  getter closing = Channel(Nil).new(1)

  def on_close(document : Larimar::TextDocument) : Nil
    closing.send(nil)
    close_gate.receive?
  end

  def on_change(document : Larimar::TextDocument) : Nil
    @changed << document
  end

  def on_save(document : Larimar::TextDocument) : Nil
    @saved << document
  end
end

# Yields its semantic tokens in two chunks, returning the last one
private class ChunkedTokensProvider < Larimar::Provider
  include Larimar::SemanticTokensRangeProvider

  def provide_semantic_tokens_range(
    document : Larimar::TextDocument,
    range : LSProtocol::Range,
    token : CancellationToken?,
    & : Array(Larimar::SemanticToken) -> Nil
  ) : Array(Larimar::SemanticToken)?
    yield [Larimar::SemanticToken.new(line: 0, char: 1, size: 2, type: :keyword)]
    yield [Larimar::SemanticToken.new(line: 1, char: 0, size: 3, type: :string)]

    [Larimar::SemanticToken.new(line: 0, char: 4, size: 1, type: :number)]
  end
end

private def range_tokens_request(partial_result_token = nil)
  LSProtocol.parse_message({
    jsonrpc: "2.0",
    id:      1,
    method:  "textDocument/semanticTokens/range",
    params:  {
      textDocument:       {uri: URI_STRING},
      range:              {start: {line: 0, character: 0}, end: {line: 9, character: 0}},
      partialResultToken: partial_result_token,
    },
  }.to_json).as(LSProtocol::SemanticTokensRangeRequest)
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
private def handle_while_closing(controller, provider, message)
  closed = Channel(Nil).new
  done = Channel(Nil).new

  spawn do
    controller.on_notification(close_notification)
    closed.send(nil)
  end
  # The closing holds the lock of the document from now on
  provider.closing.receive

  spawn do
    controller.on_notification(message)
    done.send(nil)
  end
  # Lets the spawned fiber reach the lock of the document
  sleep 10.milliseconds

  provider.close_gate.close
  closed.receive
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
    handle_while_closing(controller, provider, change_notification)

    provider.changed.should be_empty
  end

  it "doesn't pass a document saved while getting closed to the providers" do
    provider = RecordingProvider.new
    controller = new_controller(provider)

    controller.on_notification(open_notification)
    handle_while_closing(controller, provider, save_notification)

    provider.saved.should be_empty
  end

  describe "codeAction/resolve" do
    it "leaves a code action no provider resolves as is" do
      controller = new_controller(RecordingProvider.new)
      request = LSProtocol.parse_message(
        %({"jsonrpc":"2.0","id":1,"method":"codeAction/resolve","params":{"title":"Fix it","kind":"quickfix","data":{"foo":1}}})
      ).as(LSProtocol::CodeActionResolveRequest)

      response = controller.on_request(request, CancellationTokenSource.new.token)
      JSON.parse(response.to_json)["result"].should eq(JSON.parse(request.params.to_json))
    end
  end

  describe "textDocument/semanticTokens/range" do
    all_data = [0, 1, 2, 15, 0, 1, 0, 3, 18, 0, 0, 4, 1, 19, 0].map(&.to_u32)

    it "answers with every token, yielded or returned" do
      controller = new_controller(ChunkedTokensProvider.new)
      controller.on_notification(open_notification)

      response = controller.on_request(range_tokens_request, CancellationTokenSource.new.token)
      response.as(LSProtocol::SemanticTokensRangeResponse).result.try(&.data).should eq(all_data)
      controller.server.output.to_s.should_not contain("$/progress")
    end

    it "reports the tokens as partial results if asked to, answering with none" do
      controller = new_controller(ChunkedTokensProvider.new)
      controller.on_notification(open_notification)

      response = controller.on_request(range_tokens_request("p"), CancellationTokenSource.new.token)
      response.as(LSProtocol::SemanticTokensRangeResponse).result.try(&.data).should eq([] of UInt32)

      reported = controller.server.output.to_s.split(/Content-Length: \d+\r\n\r\n/, remove_empty: true).map do |json|
        progress = LSProtocol::ProgressNotification.from_json(json)
        progress.params.token.should eq("p")
        progress.params.value.not_nil!["data"].as_a.map(&.as_i.to_u32)
      end
      reported.flatten.should eq(all_data)
      reported.size.should eq(3)
    end
  end
end
