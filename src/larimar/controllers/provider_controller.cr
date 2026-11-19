class Larimar::ProviderController < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  getter capabilities : LSProtocol::ClientCapabilities?
  getter workspace_folders : Array(LSProtocol::WorkspaceFolder)?

  # The encoding of the character offsets in the positions, as negotiated with the client
  getter position_encoding : LSProtocol::PositionEncodingKind = :utf8

  # Notifications are handled concurrently, each in its own fiber
  @documents : Hash(URI, TextDocument) = Hash(URI, TextDocument).new
  @documents_mutex : Mutex = Mutex.new

  @providers : Array(Provider) = Array(Provider).new

  def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult
    @capabilities = init_params.capabilities
    @workspace_folders = init_params.workspace_folders
    @position_encoding = handle_pos_encoding(init_params)

    @providers.each do |provider|
      provider.on_init(init_params)
    end

    LSProtocol::InitializeResult.new(
      LSProtocol::ServerCapabilities.new(
        text_document_sync: LSProtocol::TextDocumentSyncKind::Incremental,
        position_encoding: @position_encoding,
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
        code_action_provider: if @providers.any?(CodeActionProvider)
          LSProtocol::CodeActionOptions.new(
            resolve_provider: true
          )
        end,
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

  private def handle_pos_encoding(init_params)
    position_encodings = init_params.capabilities.general.try &.position_encodings

    if position_encodings.try(&.any? { |e| e.in?("utf8", "utf-8") || (e.is_a?(LSProtocol::PositionEncodingKind) && e.utf8?) })
      LSProtocol::PositionEncodingKind::Utf8
    else
      LSProtocol::PositionEncodingKind::Utf16
    end
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

  # Returns the open document with the given *uri*, or `nil` if there's none
  def document?(uri : URI) : TextDocument?
    @documents_mutex.synchronize { @documents[uri]? }
  end

  # Notifications

  def on_notification(message : LSProtocol::DidOpenTextDocumentNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    document = Larimar::TextDocument.new(
      params.text_document.text,
      params.text_document.uri,
      params.text_document.version,
      position_encoding
    )

    # Published while locked, so that nothing gets to use the document
    # before the providers had a chance to handle its opening
    document.mutex.write do
      @documents_mutex.synchronize { @documents[document_uri] = document }

      @providers.each do |provider|
        provider.on_open(document)
      end
    end
  end

  def on_notification(message : LSProtocol::DidCloseTextDocumentNotification) : Nil
    writing_document(message.params.text_document.uri) do |document|
      @documents_mutex.synchronize { @documents.delete(document.uri) }

      @providers.each do |provider|
        provider.on_close(document)
      end
    end
  end

  def on_notification(message : LSProtocol::DidChangeTextDocumentNotification) : Nil
    params = message.params
    version = params.text_document.version

    writing_document(params.text_document.uri) do |document|
      params.content_changes.each do |change|
        case change
        when LSProtocol::TextDocumentContentChangeWholeDocument
          document.update_whole(change.text, version: version)
        when LSProtocol::TextDocumentContentChangePartial
          document.update_partial(change.range, change.text, version: version)
        end
      end

      @providers.each do |provider|
        provider.on_change(document)
      end
    end
  end

  def on_notification(message : LSProtocol::DidSaveTextDocumentNotification) : Nil
    writing_document(message.params.text_document.uri) do |document|
      @providers.each do |provider|
        provider.on_save(document)
      end
    end
  end

  # Yields the open document with the given *uri* while holding its write
  # lock, unless it has been closed (or reopened as another document) since.
  #
  # Each notification is handled in its own fiber, so a change might get handled
  # after the document has been closed, while waiting for its lock.
  private def writing_document(uri : URI, &) : Nil
    return unless (document = document?(uri))

    document.mutex.write do
      yield document if document?(uri).same?(document)
    end
  end

  # Requests

  def on_request(message : LSProtocol::DocumentSymbolRequest, cancel_token : CancellationToken)
    reading_document(message.params.text_document.uri) do |document|
      symbols = collect(DocumentSymbolProvider, [] of LSProtocol::DocumentSymbol) do |provider|
        provider.provide_document_symbols(document, cancel_token)
      end

      LSProtocol::DocumentSymbolResponse.new(id: message.id, result: symbols)
    end
  end

  def on_request(message : LSProtocol::CompletionRequest, cancel_token : CancellationToken)
    params = message.params

    reading_document(params.text_document.uri) do |document|
      completion_items = collect(CompletionItemProvider, [] of LSProtocol::CompletionItem) do |provider|
        provider.provide_completion_items(document, params.position, cancel_token)
      end

      LSProtocol::CompletionResponse.new(id: message.id, result: completion_items)
    end
  end

  def on_request(message : LSProtocol::DefinitionRequest, cancel_token : CancellationToken)
    params = message.params

    reading_document(params.text_document.uri) do |document|
      definition = first(DefinitionProvider) do |provider|
        provider.provide_definition(document, params.position, cancel_token)
      end

      LSProtocol::DefinitionResponse.new(id: message.id, result: definition)
    end
  end

  def on_request(message : LSProtocol::FoldingRangeRequest, cancel_token : CancellationToken)
    reading_document(message.params.text_document.uri) do |document|
      folding_ranges = collect(FoldingRangeProvider, [] of LSProtocol::FoldingRange) do |provider|
        provider.provide_folding_ranges(document, cancel_token)
      end

      LSProtocol::FoldingRangeResponse.new(id: message.id, result: folding_ranges)
    end
  end

  def on_request(message : LSProtocol::CodeActionRequest, cancel_token : CancellationToken)
    params = message.params

    reading_document(params.text_document.uri) do |document|
      code_actions = collect(CodeActionProvider, [] of LSProtocol::CodeAction | LSProtocol::Command) do |provider|
        provider.provide_code_actions(document, params.range, params.context, cancel_token)
      end

      LSProtocol::CodeActionResponse.new(id: message.id, result: code_actions)
    end
  end

  def on_request(message : LSProtocol::CodeActionResolveRequest, cancel_token : CancellationToken)
    code_action = first(CodeActionProvider) do |provider|
      provider.resolve_code_action(message.params, cancel_token)
    end

    # One no provider resolves is left as is
    LSProtocol::CodeActionResolveResponse.new(
      id: message.id,
      result: code_action || message.params
    )
  end

  def on_request(message : LSProtocol::HoverRequest, cancel_token : CancellationToken)
    params = message.params

    reading_document(params.text_document.uri) do |document|
      hover = first(HoverProvider) do |provider|
        provider.provide_hover(document, params.position, cancel_token)
      end

      LSProtocol::HoverResponse.new(id: message.id, result: hover) if hover
    end
  end

  def on_request(message : LSProtocol::InlayHintRequest, cancel_token : CancellationToken)
    params = message.params

    reading_document(params.text_document.uri) do |document|
      inlay_hints = collect(InlayHintProvider, [] of LSProtocol::InlayHint) do |provider|
        provider.provide_inlay_hints(document, params.range, cancel_token)
      end

      LSProtocol::InlayHintResponse.new(id: message.id, result: inlay_hints)
    end
  end

  def on_request(message : LSProtocol::DocumentFormattingRequest, cancel_token : CancellationToken)
    params = message.params

    reading_document(params.text_document.uri) do |document|
      edits = first(FormattingProvider) do |provider|
        provider.provide_document_formatting_edits(document, params.options, cancel_token)
      end

      LSProtocol::DocumentFormattingResponse.new(
        id: message.id,
        result: edits || [] of LSProtocol::TextEdit
      )
    end
  end

  def on_request(message : LSProtocol::SemanticTokensRequest, cancel_token : CancellationToken)
    reading_document(message.params.text_document.uri) do |document|
      tokens = collect(SemanticTokensProvider, [] of SemanticToken) do |provider|
        provider.provide_semantic_tokens(document, cancel_token)
      end

      LSProtocol::SemanticTokensResponse.new(
        id: message.id,
        result: LSProtocol::SemanticTokens.new(data: tokens.flat_map(&.to_a))
      )
    end
  end

  def on_request(message : LSProtocol::SemanticTokensRangeRequest, cancel_token : CancellationToken)
    params = message.params

    partial_result_token = params.partial_result_token

    reading_document(params.text_document.uri) do |document|
      # The tokens not reported as partial results
      data = [] of UInt32

      remaining_tokens = first(SemanticTokensRangeProvider) do |provider|
        provider.provide_semantic_tokens_range(document, params.range, cancel_token) do |tokens|
          report_semantic_tokens(tokens, partial_result_token, data)
        end
      end

      # The tokens returned follow the ones yielded
      remaining_tokens.try { |tokens| report_semantic_tokens(tokens, partial_result_token, data) }

      # Once reported as partial results, the final result is empty, as per LSP
      LSProtocol::SemanticTokensRangeResponse.new(
        id: message.id,
        result: LSProtocol::SemanticTokens.new(data: data)
      )
    end
  end

  # Reports the semantic *tokens* as a partial result if the client asked
  # for them with a *partial_result_token*, appending them to *data* otherwise.
  private def report_semantic_tokens(tokens : Array(SemanticToken), partial_result_token : LSProtocol::ProgressToken?, data : Array(UInt32)) : Nil
    unless partial_result_token
      data.concat(tokens.flat_map(&.to_a))
      return
    end

    return if tokens.empty?

    server.send_msg(
      LSProtocol::ProgressNotification.new(
        params: LSProtocol::ProgressParams.new(
          token: partial_result_token,
          value: JSON.parse(
            LSProtocol::SemanticTokens.new(data: tokens.flat_map(&.to_a)).to_json
          )
        )
      )
    )
  end

  # Yields the open document with the given *uri* while holding its read
  # lock, returning the value of the block, or `nil` if there's no such document.
  private def reading_document(uri : URI, &)
    return unless (document = document?(uri))

    document.mutex.read { yield document }
  end

  # Concatenates into *results* the ones of every provider implementing
  # *type*, as returned by the block.
  private def collect(type : T.class, results : Array, &) forall T
    @providers.each do |provider|
      next unless (typed_provider = provider.as?(T))

      if (result = yield typed_provider)
        results.concat(result)
      end
    end

    results
  end

  # Returns the first result of a provider implementing *type*,
  # as returned by the block, or `nil` if there's none.
  private def first(type : T.class, &) forall T
    @providers.each do |provider|
      next unless (typed_provider = provider.as?(T))

      if (result = yield typed_provider)
        return result
      end
    end
  end
end
