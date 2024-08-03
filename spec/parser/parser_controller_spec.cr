require "../spec_helper"

describe Larimar::Parser::Controller do
  context ".generate_semantic_tokens" do
    it "converts tokens to semantic tokens (require)" do
      document = Larimar::Parser::Document.new <<-SRC
      require "json"
      world
      SRC

      Larimar::Parser::Lexer.lex_full(document)
      Larimar::Parser::Controller.generate_semantic_tokens(document)

      document.semantic_tokens.should eq([
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 0, size: 7, type: :KEYWORD
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 8, size: 6, type: :STRING
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 1, char: 0, size: 5, type: :VARIABLE
        ),
      ])
    end

    it "converts tokens to semantic tokens (if)" do
      document = Larimar::Parser::Document.new <<-SRC
      if a.nil?
      SRC

      Larimar::Parser::Lexer.lex_full(document)
      Larimar::Parser::Controller.generate_semantic_tokens(document)

      document.semantic_tokens.should eq([
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 0, size: 2, type: :KEYWORD
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 3, size: 1, type: :VARIABLE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 1, size: 1, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 1, size: 4, type: :KEYWORD
        ),
      ])
    end

    it "convets tokens to semantic tokens (string)" do
      document = Larimar::Parser::Document.new <<-SRC
      puts "string \#{hello there + ""}".as?(String)
      SRC

      Larimar::Parser::Lexer.lex_full(document)
      Larimar::Parser::Controller.generate_semantic_tokens(document)

      document.semantic_tokens.should eq([
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 0, size: 4, type: :VARIABLE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 5, size: 25, type: :STRING
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 25, size: 3, type: :STRING
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 3, size: 1, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 1, size: 3, type: :KEYWORD
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 3, size: 1, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 1, size: 6, type: :NAMESPACE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 6, size: 1, type: :OPERATOR
        ),
      ])
    end

    it "converts tokens to semantic tokens (case)" do
      document = Larimar::Parser::Document.new <<-SRC
      type = case token.kind
             when .ident?
              LSProtocol::SemanticTokenTypes::Variable
      SRC

      Larimar::Parser::Lexer.lex_full(document)
      Larimar::Parser::Controller.generate_semantic_tokens(document)

      document.semantic_tokens.should eq([
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 0, size: 4, type: :VARIABLE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 5, size: 1, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 2, size: 4, type: :KEYWORD
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 5, size: 5, type: :VARIABLE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 5, size: 1, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 1, size: 4, type: :VARIABLE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 1, char: 7, size: 4, type: :KEYWORD
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 5, size: 1, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 1, size: 6, type: :VARIABLE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 1, char: 8, size: 10, type: :NAMESPACE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 10, size: 2, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 2, size: 18, type: :NAMESPACE
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 18, size: 2, type: :OPERATOR
        ),
        Larimar::SemanticTokensVisitor::SemanticToken.new(
          line: 0, char: 2, size: 8, type: :NAMESPACE
        ),
      ])
    end
  end
end
