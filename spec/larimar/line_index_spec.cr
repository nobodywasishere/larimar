require "../spec_helper"

# "é" takes 2 UTF-8 code units, "😀" takes 4 UTF-8 and 2 UTF-16 code units
private SOURCE = "x\naé😀b"

describe Larimar::LineIndex do
  describe "#character" do
    it "keeps byte columns for UTF-8" do
      Larimar::LineIndex.new(SOURCE, :utf8).character(1, 7).should eq(7)
    end

    it "converts byte columns for UTF-16" do
      index = Larimar::LineIndex.new(SOURCE, :utf16)

      {0 => 0, 1 => 1, 3 => 2, 7 => 4, 8 => 5}.each do |byte_column, character|
        index.character(1, byte_column).should eq(character)
      end
    end

    it "converts byte columns for UTF-32" do
      Larimar::LineIndex.new(SOURCE, :utf32).character(1, 7).should eq(3)
    end

    it "only counts the characters of the given line" do
      Larimar::LineIndex.new("😀\n😀", :utf16).character(1, 4).should eq(2)
    end
  end
end
