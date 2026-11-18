require "../spec_helper"

describe Larimar::Parser::Lexer do
  it "lexes a document fully" do
    document = Larimar::Parser::Document.new <<-SRC
      hello
      world
      SRC

    Larimar::Parser::Lexer.lex_full(document)

    document.tokens.should eq([
      Larimar::Parser::Token.new(:IDENT, 0, 5, false),
      Larimar::Parser::Token.new(:IDENT, 1, 6, true),
      Larimar::Parser::Token.new(:EOF, 0, 0, false),
    ])
    document.lex_errors.size.should eq(0)
  end

  it "lexes an unterminated char literal at the end of the document" do
    document = Larimar::Parser::Document.new("x = 'a")

    Larimar::Parser::Lexer.lex_full(document)

    document.tokens.map(&.kind).should eq([
      Larimar::Parser::TokenKind::IDENT,
      Larimar::Parser::TokenKind::OP_EQ,
      Larimar::Parser::TokenKind::VT_SKIPPED,
      Larimar::Parser::TokenKind::EOF,
    ])
    document.tokens.sum(&.length).should eq(6)
    document.lex_errors.map(&.message).should eq(["unterminated char literal, use double quotes for strings"])
  end
end
