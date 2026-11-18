# Converts the points of tree-sitter, whose columns are byte offsets,
# into LSP positions expressed in the code units of a given encoding.
struct Larimar::LineIndex
  @line_starts : Array(Int32)

  def initialize(@source : String, @encoding : LSProtocol::PositionEncodingKind)
    @line_starts = TextDocument.line_starts(@source)
  end

  def position(point : TreeSitter::Point) : LSProtocol::Position
    LSProtocol::Position.new(
      line: point.row.to_u32,
      character: character(point.row, point.column)
    )
  end

  # Returns the character offset of the *byte_column* within the line *row*.
  def character(row : Int, byte_column : Int) : UInt32
    return byte_column.to_u32 if @encoding.utf8?
    return byte_column.to_u32 unless (line_start = @line_starts[row]?)

    line_end = Math.min(line_start + byte_column, @source.bytesize)

    @source
      .byte_slice(line_start, line_end - line_start)
      .each_char
      .sum { |char| TextDocument.code_units(char, @encoding) }
      .to_u32
  end
end
