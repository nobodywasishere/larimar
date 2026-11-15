require "../spec_helper"

private URI_SUBJECT = URI.parse("file:///nonexistent/spec_subject.cr")

# "é" takes 2 UTF-8 code units, "😀" takes 4 UTF-8 and 2 UTF-16 code units
private TEXT = "aé😀b\nc"

private def document(encoding : LSProtocol::PositionEncodingKind, text = TEXT)
  Larimar::TextDocument.new(text, URI_SUBJECT, position_encoding: encoding)
end

private def position(line, character)
  LSProtocol::Position.new(line: line.to_u32, character: character.to_u32)
end

private def to_tuple(position : LSProtocol::Position)
  {position.line, position.character}
end

private def range(start_line, start_character, end_line, end_character)
  LSProtocol::Range.new(
    start: position(start_line, start_character),
    end: position(end_line, end_character)
  )
end

describe Larimar::TextDocument do
  describe "#position_to_index" do
    it "counts UTF-16 code units by default" do
      Larimar::TextDocument.new(TEXT, URI_SUBJECT)
        .position_to_index(position(0, 4)).should eq(3)
    end

    {% for encoding, offsets in {
                                  utf8:  [0, 1, 3, 7, 8],
                                  utf16: [0, 1, 2, 4, 5],
                                  utf32: [0, 1, 2, 3, 4],
                                } %}
      it "counts {{ encoding.id }} code units" do
        document = document(:{{ encoding.id }})

        {{ offsets }}.each_with_index do |offset, index|
          document.position_to_index(position(0, offset)).should eq(index)
        end
        document.position_to_index(position(1, 1)).should eq(6)
      end
    {% end %}

    it "resolves an offset past the end of a line to its end" do
      document = document(:utf16, "ab\r\ncd")

      document.position_to_index(position(0, 99)).should eq(2)
      document.position_to_index(position(1, 99)).should eq(6)
    end

    it "raises for a line past the end of the document" do
      expect_raises(IndexError) do
        document(:utf16).position_to_index(position(2, 0))
      end
    end
  end

  describe "#index_to_position" do
    {% for encoding, offsets in {
                                  utf8:  [0, 1, 3, 7, 8],
                                  utf16: [0, 1, 2, 4, 5],
                                  utf32: [0, 1, 2, 3, 4],
                                } %}
      it "counts {{ encoding.id }} code units" do
        document = document(:{{ encoding.id }})

        {{ offsets }}.each_with_index do |offset, index|
          to_tuple(document.index_to_position(index)).should eq({0, offset})
        end
        to_tuple(document.index_to_position(6)).should eq({1, 1})
      end
    {% end %}

    it "raises for an index past the end of the document" do
      expect_raises(IndexError) do
        document(:utf16).index_to_position(TEXT.size + 1)
      end
    end
  end

  describe "#update_partial" do
    it "replaces the text after a non-ASCII character" do
      document = document(:utf16)
      document.update_partial(range(0, 4, 0, 5), "x")
      document.to_s.should eq("aé😀x\nc")
    end

    it "replaces a non-ASCII character" do
      document = document(:utf8)
      document.update_partial(range(0, 3, 0, 7), "🙂")
      document.to_s.should eq("aé🙂b\nc")
    end
  end
end
