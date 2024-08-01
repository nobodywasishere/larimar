# Controller built using the Larimar parser
class Larimar::Parser::Controller < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new
  @documents : Hash(URI, Parser::Document) = Hash(URI, Parser::Document).new
  @errors : Hash(URI, Array(LSProtocol::Diagnostic)) = Hash(URI, Array(LSProtocol::Diagnostic)).new

  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(
      LSProtocol::ServerCapabilities.new(
        text_document_sync: LSProtocol::TextDocumentSyncKind::Incremental,
        # document_formatting_provider: true,
        semantic_tokens_provider: LSProtocol::SemanticTokensOptions.new(
          legend: LSProtocol::SemanticTokensLegend.new(
            token_types: LSProtocol::SemanticTokenTypes.names.map(&.downcase),
            token_modifiers: LSProtocol::SemanticTokenModifiers.names.map(&.downcase),
          ),
          full: true,
          range: false,
        )
      )
    )
  end

  # Temp for testing Document
  def on_request(message : LSProtocol::TextDocumentFormattingRequest)
    @pending_requests << message.id

    params = message.params
    document_uri = params.text_document.uri

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      GC.disable
      document.update_whole Crystal.format(document.to_s)
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
            start: LSProtocol::Position.new(
              line: 0, character: 0
            ),
            end: LSProtocol::Position.new(
              line: (document.line_count + 1).to_u32, character: 0_u32
            )
          ),
          new_text: document.to_s
        ),
      ]
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

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      lexed_tokens, errors = Larimar::Parser::Lexer.lex(document)
      tokens, diagnostics = convert_tokens_and_errors(document, lexed_tokens, errors)

      @errors[document_uri] = diagnostics
      update_errors(document_uri)
    rescue e
      Log.error(exception: e) { "Error when parsing semantic tokens - #{e}\n#{e.backtrace.join("\n")}" }
    end

    LSProtocol::TextDocumentSemanticTokensFullResponse.new(
      id: message.id,
      result: LSProtocol::SemanticTokens.new(
        data: tokens.map(&.to_a).flatten
      )
    )
  end

  private def convert_tokens_and_errors(
    document : Document, tokens : Array(Token), errors : Array(Lexer::LexerError)
  ) : {Array(SemanticTokensVisitor::SemanticToken), Array(LSProtocol::Diagnostic)}
    semantic = [] of SemanticTokensVisitor::SemanticToken
    diagnostics = [] of LSProtocol::Diagnostic
    prev_position = LSProtocol::Position.new(line: 0, character: 0)

    tokens.each do |token|
      position = document.index_to_position(token.start)

      line_diff = position.line - prev_position.line
      if line_diff > 0
        colm_diff = position.character
      else
        colm_diff = position.character - prev_position.character
      end

      prev_position = position

      type = case token.kind
             when .ident?
               LSProtocol::SemanticTokenTypes::Variable
             when .const?
               LSProtocol::SemanticTokenTypes::Namespace
             when .string?, .char?
               LSProtocol::SemanticTokenTypes::String
             when .instance_var?, .class_var?
               LSProtocol::SemanticTokenTypes::Property
             when .operator?
               LSProtocol::SemanticTokenTypes::Operator
             when .keyword?
               LSProtocol::SemanticTokenTypes::Keyword
             when .number?
               LSProtocol::SemanticTokenTypes::Number
             else
               LSProtocol::SemanticTokenTypes::Type
             end

      semantic << SemanticTokensVisitor::SemanticToken.new(
        line: line_diff.to_i32, char: colm_diff.to_i32,
        size: token.text_length, type: type
      )

      if errs = errors.select { |e| token.start <= e.pos <= (token.start + token.text_length) }
        errs.each do |err|
          diagnostics << LSProtocol::Diagnostic.new(
            message: err.message,
            range: LSProtocol::Range.new(
              start: LSProtocol::Position.new(
                line: position.line,
                character: position.character
              ),
              end: LSProtocol::Position.new(
                line: position.line,
                character: (position.character + token.text_length).to_u32
              )
            )
          )
        end
      end

      previous_position = position
    end

    {semantic, diagnostics}
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

    document = Document.new(
      params.text_document.text,
      params.text_document.version
    )

    @errors[document_uri] = Array(LSProtocol::Diagnostic).new

    document.mutex.synchronize do
      lexed_tokens, errors = Larimar::Parser::Lexer.lex(document)
      tokens, diagnostics = convert_tokens_and_errors(document, lexed_tokens, errors)

      @errors[document_uri] = diagnostics
      update_errors(document_uri)
    end

    @documents[document_uri] = document
  end

  def on_notification(message : LSProtocol::TextDocumentDidCloseNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      @documents.delete(document_uri)
      @errors.delete(document_uri)
    end
  end

  def on_notification(message : LSProtocol::TextDocumentDidChangeNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri
    changes = params.content_changes

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      changes.each do |change|
        case change
        when LSProtocol::TextDocumentContentChangeWholeDocument
          document.update_whole(change.text, version: params.text_document.version)
        when LSProtocol::TextDocumentContentChangePartial
          document.update_partial(change.range, change.text, version: params.text_document.version)
        end
      end

      lexed_tokens, errors = Larimar::Parser::Lexer.lex(document)
      tokens, diagnostics = convert_tokens_and_errors(document, lexed_tokens, errors)

      @errors[document_uri] = diagnostics
      update_errors(document_uri)
    end
  end

  def on_notification(message : LSProtocol::TextDocumentDidSaveNotification) : Nil
  end

  def on_notification(message : LSProtocol::WorkspaceDidChangeWatchedFilesNotification) : Nil
  end

  def update_errors(document_uri)
    server.send_msg(
      LSProtocol::TextDocumentPublishDiagnosticsNotification.new(
        params: LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: @errors[document_uri],
          uri: document_uri
        )
      )
    )
  end
end
