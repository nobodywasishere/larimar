class Larimar::ProviderController < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  @client_capabilities : LSProtocol::ClientCapabilities?

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new
  @documents : Hash(URI, TextDocument) = Hash(URI, TextDocument).new

  @providers : Array(Provider) = Array(Provider).new

  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::InitializeResult
    @client_capabilities = capabilites

    LSProtocol::InitializeResult.new(
      LSProtocol::ServerCapabilities.new(
        text_document_sync: LSProtocol::TextDocumentSyncKind::Incremental,
        document_formatting_provider: @providers.any?(FormattingProvider),
        document_symbol_provider: @providers.any?(DocumentSymbolProvider),
        completion_provider: if @providers.any?(CompletionItemProvider)
          LSProtocol::CompletionOptions.new(
            trigger_characters: [":", ".", "@"]
          )
        end,
        definition_provider: @providers.any?(DefinitionProvider),
        folding_range_provider: @providers.any?(FoldingRangeProvider),
        hover_provider: @providers.any?(HoverProvider),
        inlay_hint_provider: @providers.any?(InlayHintProvider),
        semantic_tokens_provider: if @providers.any?(SemanticTokensProvider)
          LSProtocol::SemanticTokensOptions.new(
            legend: LSProtocol::SemanticTokensLegend.new(
              token_types: LSProtocol::SemanticTokenTypes.names.map(&.downcase),
              token_modifiers: LSProtocol::SemanticTokenModifiers.names.map(&.downcase),
            ),
            full: true,
            range: false,
          )
        end,
      )
    )
  end

  def register_provider(provider : Provider) : Nil
    provider.controller = self
    @providers << provider
  end

  # Notifications

  def on_notification(message : LSProtocol::DidOpenTextDocumentNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    document = Larimar::TextDocument.new(
      params.text_document.text,
      params.text_document.uri,
      params.text_document.version
    )

    @documents[document_uri] = document

    document.mutex.synchronize do
      @providers.each do |provider|
        provider.on_open(document)
      end
    end
  end

  def on_notification(message : LSProtocol::DidCloseTextDocumentNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @documents.delete(document_uri)

      @providers.each do |provider|
        provider.on_close(document)
      end
    end
  end

  def on_notification(message : LSProtocol::DidChangeTextDocumentNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri
    changes = params.content_changes

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      changes.each do |change|
        case change
        when LSProtocol::TextDocumentContentChangeWholeDocument
          document.update_whole(change.text, version: params.text_document.version)
          # Larimar::Parser::Lexer.lex_full(document)
        when LSProtocol::TextDocumentContentChangePartial
          document.update_partial(change.range, change.text, version: params.text_document.version)
          # Larimar::Parser::Lexer.lex_partial(document, change.range, change.text.size)
        end
      end

      @providers.each do |provider|
        provider.on_change(document)
      end
    end
  end

  def on_notification(message : LSProtocol::DidSaveTextDocumentNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        provider.on_save(document)
      end
    end
  end

  # Requests

  def on_request(message : LSProtocol::DocumentSymbolRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    symbols = [] of LSProtocol::SymbolInformation

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(DocumentSymbolProvider)
          if result = provider.provide_document_symbols(document, nil)
            symbols.concat result
          end
        end
      end
    end

    LSProtocol::DocumentSymbolResponse.new(
      id: message.id,
      result: symbols
    )
  end

  def on_request(message : LSProtocol::CompletionRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    position = params.position
    completion_items = [] of LSProtocol::CompletionItem

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(CompletionItemProvider)
          if result = provider.provide_completion_items(document, position, nil)
            completion_items.concat result
          end
        end
      end
    end

    LSProtocol::CompletionResponse.new(
      id: message.id,
      result: completion_items
    )
  end

  def on_request(message : LSProtocol::DefinitionRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    position = params.position
    definition : LSProtocol::DefinitionResult = nil

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(DefinitionProvider)
          if result = provider.provide_definition(document, position, nil)
            definition = result
            break
          end
        end
      end
    end

    LSProtocol::DefinitionResponse.new(
      id: message.id,
      result: definition
    )
  end

  def on_request(message : LSProtocol::FoldingRangeRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    folding_ranges = Array(LSProtocol::FoldingRange).new

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(FoldingRangeProvider)
          if result = provider.provide_folding_ranges(document, nil)
            folding_ranges.push result
          end
        end
      end
    end

    LSProtocol::FoldingRangeResponse.new(
      id: message.id,
      result: folding_ranges
    )
  end

  def on_request(message : LSProtocol::HoverRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    position = params.position
    hover : LSProtocol::Hover? = nil

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(HoverProvider)
          if result = provider.provide_hover(document, position, nil)
            hover = result
            break
          end
        end
      end
    end

    LSProtocol::HoverResponse.new(
      id: message.id,
      result: hover
    )
  end

  def on_request(message : LSProtocol::InlayHintRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    range = params.range
    inlay_hints = Array(LSProtocol::InlayHint).new

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(InlayHintProvider)
          if result = provider.provide_inlay_hints(document, range, nil)
            inlay_hints.concat result
          end
        end
      end
    end

    LSProtocol::InlayHintResponse.new(
      id: message.id,
      result: inlay_hints
    )
  end

  def on_request(message : LSProtocol::DocumentFormattingRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    options = params.options
    edits = Array(LSProtocol::TextEdit).new

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(FormattingProvider)
          if result = provider.provide_document_formatting_edits(document, options, nil)
            edits = result
            break
          end
        end
      end
    end

    LSProtocol::DocumentFormattingResponse.new(
      id: message.id,
      result: edits
    )
  end

  def on_request(message : LSProtocol::SemanticTokensRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri
    tokens = Array(SemanticTokensProvider::SemanticToken).new

    return unless document = @documents[document_uri]?

    document.mutex.synchronize do
      @providers.each do |provider|
        if provider.is_a?(SemanticTokensProvider)
          if result = provider.provide_semantic_tokens(document, nil)
            tokens.concat result
          end
        end
      end
    end

    LSProtocol::SemanticTokensResponse.new(
      id: message.id,
      result: LSProtocol::SemanticTokens.new(
        data: tokens.flat_map(&.to_a)
      )
    )
  end
end
