# Controller built using the Larimar parser
class Larimar::Parser::Controller < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new
  @documents : Hash(URI, Parser::Document) = Hash(URI, Parser::Document).new

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

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      tokens = document.semantic_tokens
    end

    LSProtocol::TextDocumentSemanticTokensFullResponse.new(
      id: message.id,
      result: LSProtocol::SemanticTokens.new(
        data: tokens.map(&.to_a).flatten
      )
    )
  end

  def self.each_token_with_pos(document, &)
    doc_idx = 0
    prev_colm = 0
    line_count = 0
    colm_count = 0

    prev_token_length = 0
    prev_position = LSProtocol::Position.new(line: 0, character: 0)

    document.tokens.each do |token|
      slice = document.slice(doc_idx, token.start)
      line_count += slice.count('\n')
      line_diff = line_count - prev_position.line

      if line_diff > 0 && slice.includes?('\n')
        colm_count = slice.size - slice.rindex('\n').not_nil! - 1
      else
        colm_count += token.start + prev_token_length
      end

      position = LSProtocol::Position.new(
        line: line_count.to_u32, character: colm_count.to_u32
      )

      yield doc_idx, token, position

      prev_position = position
      prev_token_length = token.text_length

      slice = document.slice(doc_idx + token.start, token.text_length)

      line_count += slice.count('\n')
      if slice.includes?('\n')
        colm_count = slice.size - slice.rindex('\n').not_nil! - 1
      end

      doc_idx += token.length
    end
  end

  def self.generate_semantic_tokens(document : Document)
    semantic = [] of SemanticTokensVisitor::SemanticToken

    line_diff = 0
    colm_diff = 0
    prev_position = LSProtocol::Position.new(line: 0, character: 0)

    each_token_with_pos(document) do |doc_idx, token, position|
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
             when .string?, .char?, .op_grave?
               LSProtocol::SemanticTokenTypes::String
             when .instance_var?, .class_var?
               LSProtocol::SemanticTokenTypes::Property
             when .operator?
               LSProtocol::SemanticTokenTypes::Operator
             when .keyword?
               LSProtocol::SemanticTokenTypes::Keyword
             when .number?
               LSProtocol::SemanticTokenTypes::Number
             when .symbol?
               LSProtocol::SemanticTokenTypes::EnumMember
             else
               LSProtocol::SemanticTokenTypes::Type
             end

      semantic << SemanticTokensVisitor::SemanticToken.new(
        line: line_diff.to_i32, char: colm_diff.to_i32,
        size: token.text_length, type: type
      )
    end

    document.semantic_tokens = semantic
  end

  def self.generate_diagnostics(document : Document)
    diagnostics = [] of LSProtocol::Diagnostic
    errors = document.lex_errors

    each_token_with_pos(document) do |doc_idx, token, position|
      if errs = errors.select { |e| doc_idx + token.start <= e.pos <= (doc_idx + token.length) }
        errs.each do |err|
          diagnostics << LSProtocol::Diagnostic.new(
            message: err.message,
            range: LSProtocol::Range.new(
              start: position,
              end: LSProtocol::Position.new(
                line: position.line,
                character: position.character + token.text_length
              )
            )
          )
        end
      end
    end

    document.diagnostics = diagnostics
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

    document.mutex.synchronize do
      Larimar::Parser::Lexer.lex_full(document)
      self.class.generate_semantic_tokens(document)
      self.class.generate_diagnostics(document)

      update_errors(document_uri, document.diagnostics)
    end

    @documents[document_uri] = document
  end

  def on_notification(message : LSProtocol::TextDocumentDidCloseNotification) : Nil
    params = message.params
    document_uri = params.text_document.uri

    return unless (document = @documents[document_uri]?)

    document.mutex.synchronize do
      @documents.delete(document_uri)
      update_errors(document_uri, Array(LSProtocol::Diagnostic).new)
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

          # Larimar::Parser::Lexer.lex_full(document)
        when LSProtocol::TextDocumentContentChangePartial
          document.update_partial(change.range, change.text, version: params.text_document.version)

          # Larimar::Parser::Lexer.lex_partial(document, change.range, change.text.size)
        end
      end

      Larimar::Parser::Lexer.lex_full(document)
      self.class.generate_semantic_tokens(document)
      self.class.generate_diagnostics(document)

      update_errors(document_uri, document.diagnostics)
    end
  end

  def on_notification(message : LSProtocol::TextDocumentDidSaveNotification) : Nil
  end

  def on_notification(message : LSProtocol::WorkspaceDidChangeWatchedFilesNotification) : Nil
  end

  def update_errors(document_uri, diagnostics)
    server.send_msg(
      LSProtocol::TextDocumentPublishDiagnosticsNotification.new(
        params: LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: diagnostics,
          uri: document_uri
        )
      )
    )
  end
end
