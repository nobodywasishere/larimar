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

  it "lexes a document partially" do
    document = Larimar::Parser::Document.new <<-SRC
      hello
      world
      SRC

    Larimar::Parser::Lexer.lex_full(document)

    document.tokens.size.should eq(3)
    document.lex_errors.size.should eq(0)

    range = LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: 0, character: 5
      ),
      end: LSProtocol::Position.new(
        line: 0, character: 5
      )
    )

    edit = " there1"

    document.update_partial(range, edit)

    document.to_s.should eq(<<-EDIT)
      hello there1
      world
      EDIT

    Larimar::Parser::Lexer.lex_partial(document, range, edit.size)

    document.tokens.should eq([
      Larimar::Parser::Token.new(:IDENT, 0, 5, false),
      Larimar::Parser::Token.new(:IDENT, 1, 7, false),
      Larimar::Parser::Token.new(:IDENT, 1, 6, true),
    ])
    document.lex_errors.size.should eq(0)
  end

  it "lexes a document partially and corrects keyword" do
    document = Larimar::Parser::Document.new <<-SRC
      de hello
      kenobi
      SRC

    Larimar::Parser::Lexer.lex_full(document)

    document.tokens.should eq([
      Larimar::Parser::Token.new(:IDENT, 0, 2, false),
      Larimar::Parser::Token.new(:IDENT, 1, 6, false),
      Larimar::Parser::Token.new(:IDENT, 1, 7, true),
      Larimar::Parser::Token.new(:EOF, 0, 0, false),
    ])
    document.lex_errors.size.should eq(0)

    range = LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: 0, character: 2
      ),
      end: LSProtocol::Position.new(
        line: 0, character: 2
      )
    )

    edit = "f"

    document.update_partial(range, edit)

    document.to_s.should eq(<<-EDIT)
      def hello
      kenobi
      EDIT

    Larimar::Parser::Lexer.lex_partial(document, range, edit.size)

    document.tokens.should eq([
      Larimar::Parser::Token.new(:KW_DEF, 0, 3, false),
      Larimar::Parser::Token.new(:IDENT, 1, 6, false),
      Larimar::Parser::Token.new(:IDENT, 1, 7, true),
    ])
    document.lex_errors.size.should eq(0)
  end

  it "lexes a document partially and adds keyword" do
    document = Larimar::Parser::Document.new <<-SRC
      de hello
      kenobi
      SRC

    Larimar::Parser::Lexer.lex_full(document)

    document.tokens.should eq([
      Larimar::Parser::Token.new(:IDENT, 0, 2, false),
      Larimar::Parser::Token.new(:IDENT, 1, 6, false),
      Larimar::Parser::Token.new(:IDENT, 1, 7, true),
      Larimar::Parser::Token.new(:EOF, 0, 0, false),
    ])
    document.lex_errors.size.should eq(0)

    range = LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: 0, character: 0
      ),
      end: LSProtocol::Position.new(
        line: 0, character: 2
      )
    )

    edit = "abstract def"

    document.update_partial(range, edit)

    document.to_s.should eq(<<-EDIT)
      abstract def hello
      kenobi
      EDIT

    Larimar::Parser::Lexer.lex_partial(document, range, edit.size)

    document.tokens.should eq([
      Larimar::Parser::Token.new(:KW_ABSTRACT, 0, 8, false),
      Larimar::Parser::Token.new(:KW_DEF, 1, 4, false),
      Larimar::Parser::Token.new(:IDENT, 1, 6, false),
      Larimar::Parser::Token.new(:IDENT, 1, 7, true),
    ])
    document.lex_errors.size.should eq(0)
  end
end
