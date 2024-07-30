class Larimar::Parser::Controller < Larimar::Controller
  Log = ::Larimar::Log.for(self)

  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(
      LSProtocol::ServerCapabilities.new(
        text_document_sync: LSProtocol::TextDocumentSyncKind::Full,
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
      tokens, errors = Larimar::Parser::Lexer.lex(document.contents)
      tokens, errors = convert_tokens_and_errors(document.contents, tokens, errors)
      document.cached_semantic_tokens = tokens
    rescue e
      Log.error(exception: e) { "Error when parsing semantic tokens:\n#{e}" }

      tokens = document.cached_semantic_tokens || tokens
    end

    LSProtocol::TextDocumentSemanticTokensFullResponse.new(
      id: message.id,
      result: LSProtocol::SemanticTokens.new(
        data: nil
      )
    )
  end

  private def convert_tokens_and_errors(
    contents : String, tokens : Array(Token), errors : Array(Lexer::LexerError)
  ) : {Array(SemanticTokensVisitor::SemanticToken), Array(LSProtocol::Diagnostic)}
    semantic = [] of SemanticTokensVisitor::SemanticToken
    diagnostics = [] of LSProtocol::Diagnostic
    line_count = 0
    colm_count = 0

    tokens.each do |token|
      trivia = token.trivia(contents)

      if (count = trivia.count('\n')) > 0
        line_diff = count
        line_count += count
        colm_count = (token.start - token.full_start) + trivia.rindex('\n').not_nil!
      else
        line_diff = 0
        colm_count += (token.start - token.full_start)
      end

      type = case token.kind
             when :IDENT
               LSProtocol::SemanticTokenTypes::Variable
             when :CONST
               LSProtocol::SemanticTokenTypes::Namespace
             else
               LSProtocol::SemanticTokenTypes::Type
             end

      semantic << SemanticTokensVisitor::SemanticToken.new(
        line: line_diff, char: colm_count,
        size: token.length, type: type
      )

      if errs = errors.select { |e| token.start <= e.pos <= (token.start + token.length) }
        errs.each do |err|
          diagnostics << LSProtocol::Diagnostic.new(
            message: err.message,
            range: LSProtocol::Range.new(
              start: LSProtocol::Position.new(
                line: line_count.to_u32,
                character: colm_count.to_u32
              ),
              end: LSProtocol::Position.new(
                line: line_count.to_u32,
                character: (colm_count + token.text(contents).size).to_u32
              )
            )
          )
        end
      end
    end

    {semantic, [] of LSProtocol::Diagnostic}
  end
end
