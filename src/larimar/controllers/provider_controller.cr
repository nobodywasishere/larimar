class Larimar::ProviderController < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  getter capabilities : LSProtocol::ClientCapabilities?
  getter workspace_folders : Array(LSProtocol::WorkspaceFolder)?

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new
  @cancel_tokens : Hash(Int32 | String, CancellationTokenSource) = Hash(Int32 | String, CancellationTokenSource).new

  @request_meta_mutex : Mutex = Mutex.new

  @documents : Hash(URI, TextDocument) = Hash(URI, TextDocument).new
  @providers : Array(Provider) = Array(Provider).new

  def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult
    @capabilities = init_params.capabilities
    @workspace_folders = init_params.workspace_folders

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
        semantic_tokens_provider: if @providers.any?(SemanticTokensProvider) || @providers.any?(SemanticTokensRangeProvider)
          LSProtocol::SemanticTokensOptions.new(
            legend: LSProtocol::SemanticTokensLegend.new(
              token_types: LSProtocol::SemanticTokenTypes.names.map(&.downcase),
              token_modifiers: LSProtocol::SemanticTokenModifiers.names.map(&.downcase),
            ),
            full: @providers.any?(SemanticTokensProvider),
            range: @providers.any?(SemanticTokensRangeProvider),
          )
        end,
      )
    )
  end

  def when_ready
    @providers.each do |provider|
      provider.when_ready
    end
  end

  def register_provider(provider : Provider) : Nil
    provider.controller = self
    @providers << provider
  end

  # Notifications

  def on_notification(message : LSProtocol::CancelNotification) : Nil
    @request_meta_mutex.synchronize do
      @cancel_tokens[message.params.id]?.try(&.cancel)
      @cancel_tokens.delete(message.params.id)
    end
  end

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

    return unless (document = @documents[document_uri]?)

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

    return unless (document = @documents[document_uri]?)

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

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      @providers.each do |provider|
        provider.on_save(document)
      end
    end
  end

  # Requests

  def on_request(message : LSProtocol::DocumentSymbolRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    symbols = [] of LSProtocol::DocumentSymbol

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(DocumentSymbolProvider)
          if (result = provider.provide_document_symbols(document, cancel_token))
            symbols.concat result
          end
        end
      end
    end

    LSProtocol::DocumentSymbolResponse.new(
      id: message.id,
      result: symbols
    )
  rescue CancellationException
    LSProtocol::DocumentSymbolResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::CompletionRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    position = params.position
    completion_items = [] of LSProtocol::CompletionItem

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(CompletionItemProvider)
          if (result = provider.provide_completion_items(document, position, cancel_token))
            completion_items.concat result
          end
        end
      end
    end

    LSProtocol::CompletionResponse.new(
      id: message.id,
      result: completion_items
    )
  rescue CancellationException
    LSProtocol::CompletionResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::DefinitionRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    position = params.position
    definition : LSProtocol::DefinitionResult = nil

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(DefinitionProvider)
          if (result = provider.provide_definition(document, position, cancel_token))
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
  rescue CancellationException
    LSProtocol::DefinitionResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::FoldingRangeRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    folding_ranges = Array(LSProtocol::FoldingRange).new

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(FoldingRangeProvider)
          if (result = provider.provide_folding_ranges(document, cancel_token))
            folding_ranges.concat result
          end
        end
      end
    end

    LSProtocol::FoldingRangeResponse.new(
      id: message.id,
      result: folding_ranges
    )
  rescue CancellationException
    LSProtocol::FoldingRangeResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::HoverRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    position = params.position
    hover : LSProtocol::Hover? = nil

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(HoverProvider)
          if (result = provider.provide_hover(document, position, cancel_token))
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
  rescue CancellationException
    LSProtocol::HoverResponse.new(
      id: message.id,
      result: hover
    )
  end

  def on_request(message : LSProtocol::InlayHintRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    range = params.range
    inlay_hints = Array(LSProtocol::InlayHint).new

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(InlayHintProvider)
          if (result = provider.provide_inlay_hints(document, range, cancel_token))
            inlay_hints.concat result
          end
        end
      end
    end

    LSProtocol::InlayHintResponse.new(
      id: message.id,
      result: inlay_hints
    )
  rescue CancellationException
    LSProtocol::InlayHintResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::DocumentFormattingRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    options = params.options
    edits = Array(LSProtocol::TextEdit).new

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(FormattingProvider)
          if (result = provider.provide_document_formatting_edits(document, options, cancel_token))
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
  rescue CancellationException
    LSProtocol::DocumentFormattingResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::SemanticTokensRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    document_uri = params.text_document.uri
    tokens = Array(SemanticToken).new

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(SemanticTokensProvider)
          if (result = provider.provide_semantic_tokens(document, cancel_token))
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
  rescue CancellationException
    LSProtocol::SemanticTokensResponse.new(
      id: message.id,
      result: nil
    )
  end

  def on_request(message : LSProtocol::SemanticTokensRangeRequest)
    cancel_token : CancellationToken = @request_meta_mutex.synchronize do
      @pending_requests << message.id
      @cancel_tokens[message.id] = (token_source = CancellationTokenSource.new)
      token_source.token
    end

    params = message.params
    range = params.range
    document_uri = params.text_document.uri
    tokens = Array(SemanticToken).new

    return unless (document = @documents[document_uri]?)

    document.mutex.read do
      @providers.each do |provider|
        if provider.is_a?(SemanticTokensRangeProvider)
          result = provider.provide_semantic_tokens_range(document, range, cancel_token) do |partial_tokens|
            if (partial_result_token = params.partial_result_token)
              server.send_msg(
                LSProtocol::ProgressNotification.new(
                  params: LSProtocol::ProgressParams.new(
                    token: partial_result_token,
                    value: JSON.parse(
                      LSProtocol::SemanticTokens.new(
                        data: partial_tokens.flat_map(&.to_a)
                      ).to_json
                    )
                  )
                )
              )
            end
          end

          if result
            tokens.concat result
            break
          end
        end
      end
    end

    LSProtocol::SemanticTokensRangeResponse.new(
      id: message.id,
      result: LSProtocol::SemanticTokens.new(
        data: tokens.flat_map(&.to_a)
      )
    )
  rescue CancellationException
    LSProtocol::SemanticTokensRangeResponse.new(
      id: message.id,
      result: nil
    )
  end
end
