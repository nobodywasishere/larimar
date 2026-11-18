require "../spec_helper"

private URI_SUBJECT = URI.parse("file:///nonexistent/spec_subject.cr")

# "é" takes 2 UTF-8 code units, "😀" takes 4 UTF-8 and 2 UTF-16 code units
private TEXT = "aé😀b\nc"

# Byte offsets of the characters of the first line of `TEXT`, and of its end
private BYTE_OFFSETS = [0, 1, 3, 7, 8]

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
  describe "#position_to_offset" do
    it "counts UTF-8 code units by default" do
      Larimar::TextDocument.new(TEXT, URI_SUBJECT)
        .position_to_offset(position(0, 7)).should eq(7)
    end

    {% for encoding, offsets in {
                                  utf8:  [0, 1, 3, 7, 8],
                                  utf16: [0, 1, 2, 4, 5],
                                  utf32: [0, 1, 2, 3, 4],
                                } %}
      it "counts {{ encoding.id }} code units" do
        document = document(:{{ encoding.id }})

        {{ offsets }}.zip(BYTE_OFFSETS) do |offset, byte_offset|
          document.position_to_offset(position(0, offset)).should eq(byte_offset)
        end
        document.position_to_offset(position(1, 1)).should eq(10)
      end
    {% end %}

    it "resolves an offset past the end of a line to its end" do
      document = document(:utf16, "ab\r\ncd")

      document.position_to_offset(position(0, 99)).should eq(2)
      document.position_to_offset(position(1, 99)).should eq(6)
    end

    it "raises for a line past the end of the document" do
      expect_raises(IndexError) do
        document(:utf16).position_to_offset(position(2, 0))
      end
    end
  end

  describe "#offset_to_position" do
    {% for encoding, offsets in {
                                  utf8:  [0, 1, 3, 7, 8],
                                  utf16: [0, 1, 2, 4, 5],
                                  utf32: [0, 1, 2, 3, 4],
                                } %}
      it "counts {{ encoding.id }} code units" do
        document = document(:{{ encoding.id }})

        {{ offsets }}.zip(BYTE_OFFSETS) do |offset, byte_offset|
          to_tuple(document.offset_to_position(byte_offset)).should eq({0, offset})
        end
        to_tuple(document.offset_to_position(9)).should eq({1, 0})
        to_tuple(document.offset_to_position(10)).should eq({1, 1})
      end
    {% end %}

    {% for encoding, characters in {utf8: {1, 3}, utf16: {1, 2}, utf32: {1, 2}} %}
      it "resolves an offset within a character to its start in {{ encoding.id }} code units" do
        document = document(:{{ encoding.id }})

        # Within "é", then within "😀"
        to_tuple(document.offset_to_position(2)).should eq({0, {{ characters[0] }}})
        to_tuple(document.offset_to_position(5)).should eq({0, {{ characters[1] }}})
      end
    {% end %}

    it "raises for an offset past the end of the document" do
      expect_raises(IndexError) do
        document(:utf16).offset_to_position(TEXT.bytesize + 1)
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

    it "keeps track of the lines" do
      document = document(:utf16, "ab\ncd\nef\ngh")

      # Joins the lines 1 to 2, inserting a new one
      document.update_partial(range(1, 1, 2, 1), "X\nY")
      document.to_s.should eq("ab\ncX\nYf\ngh")

      document.position_to_offset(position(1, 1)).should eq(4)
      document.position_to_offset(position(2, 1)).should eq(7)
      document.position_to_offset(position(3, 1)).should eq(10)
      to_tuple(document.offset_to_position(10)).should eq({3, 1})

      # Removes the line breaks
      document.update_partial(range(0, 2, 3, 0), "")
      document.to_s.should eq("abgh")
      document.position_to_offset(position(0, 3)).should eq(3)

      expect_raises(IndexError) do
        document.position_to_offset(position(1, 0))
      end
    end

    it "inserts the text at the start of a range ending before it" do
      document = document(:utf16, "ab\ncd")

      document.update_partial(range(1, 1, 0, 1), "X\n")
      document.to_s.should eq("ab\ncX\nd")

      document.position_to_offset(position(2, 1)).should eq(7)
    end

    it "keeps track of the lines when appending at the end" do
      document = document(:utf16, "ab")

      document.update_partial(range(0, 2, 0, 2), "\ncd\n")
      document.to_s.should eq("ab\ncd\n")

      document.position_to_offset(position(1, 1)).should eq(4)
      document.position_to_offset(position(2, 0)).should eq(6)
    end
  end

  describe "#position" do
    # "é" takes 2 UTF-8 code units, "😀" takes 4 UTF-8 and 2 UTF-16 code units
    source = "x\naé😀b"

    it "keeps byte columns for UTF-8" do
      document(:utf8, source).position(1, 7).character.should eq(7)
    end

    it "converts byte columns for UTF-16" do
      document = document(:utf16, source)

      {0 => 0, 1 => 1, 3 => 2, 7 => 4, 8 => 5}.each do |byte_column, character|
        to_tuple(document.position(1, byte_column)).should eq({1, character})
      end
    end

    it "converts byte columns for UTF-32" do
      document(:utf32, source).position(1, 7).character.should eq(3)
    end

    it "only counts the characters of the given line" do
      document(:utf16, "😀\n😀").position(1, 4).character.should eq(2)
    end

    it "resolves a column past the end of the document to its end" do
      document(:utf16, source).position(1, 99).character.should eq(5)
    end

    it "keeps the column of a line past the end of the document" do
      to_tuple(document(:utf16, source).position(5, 3)).should eq({5, 3})
    end
  end

  describe "ASCII text" do
    it "resolves the offsets past the end of a line, or at a carriage return, like any text" do
      document = document(:utf16, "ab\r\nc\rd\nef")

      document.position_to_offset(position(0, 1)).should eq(1)
      document.position_to_offset(position(0, 99)).should eq(2)
      document.position_to_offset(position(1, 1)).should eq(5)
      document.position_to_offset(position(1, 99)).should eq(5)
      document.position_to_offset(position(2, 2)).should eq(10)
      document.position_to_offset(position(2, 99)).should eq(10)

      to_tuple(document.offset_to_position(9)).should eq({2, 1})
      to_tuple(document.position(1, 2)).should eq({1, 2})
    end

    it "counts the code units again once a non-ASCII character gets inserted" do
      document = document(:utf16, "ab\ncd")

      document.update_partial(range(0, 1, 0, 1), "😀")
      document.to_s.should eq("a😀b\ncd")

      document.position_to_offset(position(0, 3)).should eq(5)
      to_tuple(document.offset_to_position(5)).should eq({0, 3})
      to_tuple(document.position(0, 5)).should eq({0, 3})

      document.update_whole("xy\nz")
      document.position_to_offset(position(0, 2)).should eq(2)
      to_tuple(document.position(1, 1)).should eq({1, 1})
    end
  end
end
