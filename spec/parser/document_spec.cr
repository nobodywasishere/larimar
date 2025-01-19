require "../spec_helper"

describe Larimar::Parser::Document do
  it "iterates over chars in a document" do
    doc = Larimar::Parser::Document.new(<<-SRC)
    hello
    world
    SRC

    doc.current_char.should eq('h')
    doc.next_char
    doc.current_char.should eq('e')
    doc.next_char
    doc.current_char.should eq('l')
    doc.next_char
    doc.current_char.should eq('l')
    doc.next_char
    doc.current_char.should eq('o')
    doc.next_char
    doc.current_char.should eq('\n')
    doc.next_char
    doc.current_char.should eq('w')
    doc.next_char
    doc.current_char.should eq('o')
    doc.next_char
    doc.current_char.should eq('r')
    doc.next_char
    doc.current_char.should eq('l')
    doc.next_char
    doc.current_char.should eq('d')
    doc.next_char
    doc.current_char.should eq('\0')

    expect_raises(IndexError) { doc.next_char }
  end

  it "can be updated with changes" do
    doc = Larimar::Parser::Document.new(<<-SRC)
    hello
    world
    SRC

    range = LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: 0, character: 5
      ),
      end: LSProtocol::Position.new(
        line: 0, character: 5
      )
    )

    edit = " there"

    doc.update_partial(range, edit)

    doc.to_s.should eq(<<-EDIT)
    hello there
    world
    EDIT

    range2 = LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: 1, character: 0
      ),
      end: LSProtocol::Position.new(
        line: 1, character: 5
      )
    )

    edit2 = "general kenobi!"

    doc.update_partial(range2, edit2)

    doc.to_s.should eq(<<-EDIT)
    hello there
    general kenobi!
    EDIT
  end
end
