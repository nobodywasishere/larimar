# Controller built using the stdlib Crystal parser/compiler
class Larimar::CrystalController < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new
  @documents : Hash(URI, Tuple(Larimar::TextDocument, Mutex)) = Hash(URI, Tuple(Larimar::TextDocument, Mutex)).new
  @documents_lock = Mutex.new

  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(
      LSProtocol::ServerCapabilities.new(
        text_document_sync: LSProtocol::TextDocumentSyncKind::Full,
        document_formatting_provider: true,
        document_symbol_provider: true,
        # semantic_tokens_provider: LSProtocol::SemanticTokensOptions.new(
        #   legend: LSProtocol::SemanticTokensLegend.new(
        #     token_types: LSProtocol::SemanticTokenTypes.names.map(&.downcase),
        #     token_modifiers: LSProtocol::SemanticTokenModifiers.names.map(&.downcase),
        #   ),
        #   full: true,
        #   range: false,
        # )
        # document_range_formatting_provider: true,
        # completion_provider: LSProtocol::CompletionOptions.new(
        #   trigger_characters: [".", ":", "@"]
        # ),
        # hover_provider: true,
        # definition_provider: true,
        # inlay_hint_provider: true
      )
    )
  end

  def when_ready
  end

  # Requests

  def on_request(message : LSProtocol::Request) : Nil
    Log.error { "Unhandled request message #{message.class.to_s.split("::").last}" }
  end

  def on_request(message : LSProtocol::TextDocumentFormattingRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri

    collection = @documents[document_uri]?
    return unless collection
    document, mutex = collection

    mutex.synchronize do
      GC.disable
      document.contents = Crystal.format(document.contents)
      GC.enable
    rescue e
      Log.error(exception: e) { "Error when formatting:\n#{e}" }

      return
    end

    LSProtocol::TextDocumentFormattingResponse.new(
      id: message.id,
      result: [
        LSProtocol::TextEdit.new(
          range: LSProtocol::Range.new(
            start: LSProtocol::Position.new(line: 0, character: 0),
            end: LSProtocol::Position.new(line: document.line_count + 1, character: 0_u32)
          ),
          new_text: document.contents
        ),
      ]
    )
  ensure
    @pending_requests.delete(message.id)
  end

  def on_request(message : LSProtocol::TextDocumentDocumentSymbolRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    symbols = [] of LSProtocol::SymbolInformation

    collection = @documents[document_uri]?
    return unless collection
    document, mutex = collection

    mutex.synchronize do
      GC.disable
      parser = Crystal::Parser.new(document.contents)
      parser.filename = document_uri.path
      parser.wants_doc = false

      visitor = DocumentSymbolsVisitor.new(params.text_document.uri)
      parser.parse.accept(visitor)

      document.cached_symbols = symbols = visitor.symbols
    rescue e
      Log.error(exception: e) { "Error when parsing:\n#{e}" }

      symbols = document.cached_symbols || symbols
    ensure
      GC.enable
    end

    LSProtocol::TextDocumentDocumentSymbolResponse.new(
      id: message.id,
      result: symbols
    )
  ensure
    @pending_requests.delete(message.id)
  end

  def on_request(message : LSProtocol::TextDocumentSemanticTokensFullRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    tokens = [] of SemanticTokensVisitor::SemanticToken
    diagnostics = [] of LSProtocol::Diagnostic

    collection = @documents[document_uri]?
    return unless collection
    document, mutex = collection

    mutex.synchronize do
      GC.disable
      parser = Crystal::Parser.new(document.contents)
      parser.filename = document_uri.path
      parser.wants_doc = false

      visitor = SemanticTokensVisitor.new
      parser.parse.accept(visitor)

      document.cached_semantic_tokens = tokens = visitor.semantic_tokens
      diagnostics = visitor.diagnostics
    rescue e
      Log.error(exception: e) { "Error when parsing semantic tokens:\n#{e}" }

      tokens = document.cached_semantic_tokens || tokens
    ensure
      GC.enable
    end

    LSProtocol::TextDocumentPublishDiagnosticsNotification.new(
      params: LSProtocol::PublishDiagnosticsParams.new(
        diagnostics: diagnostics,
        uri: document_uri
      )
    )

    LSProtocol::TextDocumentSemanticTokensFullResponse.new(
      id: message.id,
      result: LSProtocol::SemanticTokens.new(
        data: tokens.map(&.to_a).flatten
      )
    )
  ensure
    @pending_requests.delete(message.id)
  end

  # Notifications

  def on_notification(message : LSProtocol::Notification) : Nil
    Log.error { "Unhandled notification message #{message.class.to_s.split("::").last}" }
  end

  def on_notification(message : LSProtocol::SetTraceNotification) : Nil
    # TODO: Enable setting the log level via `message.params.value` ('off' | 'messages' | 'verbose')
  end

  def on_notification(message : LSProtocol::TextDocumentDidOpenNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    @documents[document_uri] = {
      TextDocument.new(
        document_uri,
        params.text_document.text
      ),
      Mutex.new,
    }
  end

  def on_notification(message : LSProtocol::TextDocumentDidCloseNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    contents = @documents[document_uri]?
    return unless contents
    document, mutex = contents

    mutex.synchronize do
      @documents.delete(document_uri)
    end
  end

  def on_notification(message : LSProtocol::TextDocumentDidChangeNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri
    changes = params.content_changes

    contents = @documents[document_uri]?
    return unless contents
    document, mutex = contents

    mutex.synchronize do
      document.update_contents(changes)
    end
  end

  def on_notification(message : LSProtocol::TextDocumentDidSaveNotification) : Nil
  end

  def on_notification(message : LSProtocol::WorkspaceDidChangeWatchedFilesNotification) : Nil
  end

  # Responses

  def on_response(message : LSProtocol::Response) : Nil
    Log.error { "Unhandled response message #{message.class.to_s.split("::").last}" }
  end
end
