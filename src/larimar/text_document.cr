class Larimar::TextDocument
  Log = ::Larimar::Log.for(self)

  @text : String

  # Byte offsets of the starts of the lines of `@text`
  @line_starts : Array(Int32)

  getter uri : URI
  getter version : Int32
  getter mutex : Sync::RWLock = Sync::RWLock.new

  # The encoding of the character offsets in the positions, as negotiated with the client
  getter position_encoding : LSProtocol::PositionEncodingKind

  def initialize(
    document : String,
    @uri : URI,
    @version : Int32 = 0,
    @position_encoding : LSProtocol::PositionEncodingKind = :utf8,
  )
    @text = document
    @line_starts = self.class.line_starts(document)
  end

  def update_partial(range : LSProtocol::Range, text : String, version : Int32 = 0) : Nil
    start_offset = position_to_offset(range.start)
    end_offset = position_to_offset(range.end)

    start_line = range.start.line.to_i
    end_line = range.end.line.to_i

    # A range ending before its start inserts *text* at its start
    if end_offset < start_offset
      end_offset = start_offset
      end_line = start_line
    end

    bytes = @text.to_slice
    @text = String.build(@text.bytesize - (end_offset - start_offset) + text.bytesize) do |io|
      io.write(bytes[0, start_offset])
      io << text
      io.write(bytes[end_offset..])
    end

    # Positions never resolve past the end of their line, so the lines up
    # to the start of the range keep their starts, the ones within it get
    # replaced by the ones of *text*, and the ones after it get shifted.
    removed_lines = end_line - start_line

    inserted_starts = self.class.line_starts(text)
    inserted_starts.shift
    inserted_starts.map! { |line_start| line_start + start_offset }

    @line_starts[start_line + 1, removed_lines] = inserted_starts

    if (delta = text.bytesize - (end_offset - start_offset)) != 0
      (start_line + 1 + inserted_starts.size...@line_starts.size).each do |line|
        @line_starts[line] += delta
      end
    end

    @version = version
    @ameba_source = nil
  end

  def update_whole(text : String, version : Int32 = 0) : Nil
    @text = text
    @line_starts = self.class.line_starts(text)
    @version = version
    @ameba_source = nil
  end

  def to_s(io : IO) : Nil
    io << @text
  end

  def to_s : String
    @text
  end

  # Returns the byte offset of the character at *position*, whose character
  # offset is expressed in the code units of `#position_encoding`.
  #
  # As per the LSP specification, a character offset past the end
  # of the line resolves to the end of that line.
  def position_to_offset(position : LSProtocol::Position) : Int32
    unless (line_start = @line_starts[position.line]?)
      raise IndexError.new("#{position.line},#{position.character} not in document")
    end

    reader = Char::Reader.new(@text, line_start)
    units = 0

    while units < position.character && reader.pos < @text.bytesize && !reader.current_char.in?('\r', '\n')
      units += self.class.code_units(reader.current_char, position_encoding)
      reader.next_char
    end

    reader.pos
  end

  # Returns the position of the character at the byte *offset*, with its
  # character offset expressed in the code units of `#position_encoding`.
  #
  # An offset within a character resolves to the start of that character.
  def offset_to_position(offset : Int32) : LSProtocol::Position
    unless 0 <= offset <= @text.bytesize
      raise IndexError.new("#{offset} not in document")
    end

    # The last line starting at or before the offset
    line = (@line_starts.bsearch_index { |line_start| line_start > offset } || @line_starts.size) - 1

    LSProtocol::Position.new(
      line: line.to_u32,
      character: character(@line_starts[line], offset).to_u32
    )
  end

  # Returns the number of code units of `#position_encoding` between
  # the byte offsets *line_start* and *offset*, the latter moved back
  # to the start of the character it's within, if any.
  private def character(line_start : Int32, offset : Int32) : Int32
    bytes = @text.to_slice

    # The bytes continuing a UTF-8 sequence are all 0b10xxxxxx
    while line_start < offset < bytes.size && bytes[offset] & 0xC0 == 0x80
      offset -= 1
    end

    return offset - line_start if position_encoding.utf8?

    reader = Char::Reader.new(@text, line_start)
    units = 0

    while reader.pos < offset
      units += self.class.code_units(reader.current_char, position_encoding)
      reader.next_char
    end

    units
  end

  # Returns the position of the byte *column* within the line *row*, like the
  # points of tree-sitter, with its character offset expressed in the code
  # units of `#position_encoding`.
  #
  # A column within a character resolves to the start of that character,
  # and one past the end of the document to its end.
  def position(row : Int, byte_column : Int) : LSProtocol::Position
    character =
      if (line_start = @line_starts[row]?)
        character(line_start, Math.min(line_start + byte_column.to_i, @text.bytesize))
      else
        byte_column
      end

    LSProtocol::Position.new(
      line: row.to_u32,
      character: character.to_u32
    )
  end

  # Returns the byte offsets of the starts of the lines of *text*.
  def self.line_starts(text : String) : Array(Int32)
    line_starts = [0]

    text.each_byte.with_index do |byte, index|
      line_starts << index + 1 if byte == '\n'.ord
    end

    line_starts
  end

  # Returns the number of code units *char* takes in the given *encoding*.
  def self.code_units(char : Char, encoding : LSProtocol::PositionEncodingKind) : Int32
    case encoding
    in .utf8?  then char.bytesize
    in .utf16? then char.ord >= 0x10000 ? 2 : 1
    in .utf32? then 1
    end
  end

  @ameba_source : Ameba::Source?

  # Readers share the lock of the document, so building the source
  # is serialized separately, to build it only once.
  @ameba_source_mutex = Mutex.new

  def ameba_source : Ameba::Source
    @ameba_source_mutex.synchronize do
      @ameba_source ||= Ameba::Source.new(
        to_s,
        uri.path
      )
    end
  end
end
