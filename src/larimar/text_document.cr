class Larimar::TextDocument
  Log = ::Larimar::Log.for(self)

  @chars : Array(Char)

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
    @chars = document.chars
  end

  def update_partial(range : LSProtocol::Range, text : String, version : Int32 = 0) : Nil
    @ameba_source = nil
    start_pos = position_to_index(range.start)
    end_pos = position_to_index(range.end)

    @chars[start_pos...end_pos] = text.chars
    @version = version
  end

  def update_whole(text : String, version : Int32 = 0) : Nil
    @ameba_source = nil
    @chars = text.chars
    @version = version
  end

  def to_s(io : IO)
    @chars.each do |char|
      io << char
    end
  end

  def to_s : String
    String.build do |str|
      to_s(str)
    end
  end

  # Returns the index of the character at *position*, whose character offset
  # is expressed in the code units of `#position_encoding`.
  #
  # As per the LSP specification, a character offset past the end
  # of the line resolves to the end of that line.
  def position_to_index(position : LSProtocol::Position) : Int32
    index = 0
    line = 0

    while line < position.line
      char = @chars[index]? ||
             raise IndexError.new("#{position.line},#{position.character} not in document")

      line += 1 if char == '\n'
      index += 1
    end

    units = 0
    while units < position.character && (char = @chars[index]?) && !char.in?('\r', '\n')
      units += self.class.code_units(char, position_encoding)
      index += 1
    end

    index
  end

  # Returns the position of the character at *index*, with its character offset
  # expressed in the code units of `#position_encoding`.
  def index_to_position(index : Int32) : LSProtocol::Position
    unless 0 <= index <= @chars.size
      raise IndexError.new("#{index} not in document")
    end

    line = 0
    character = 0

    index.times do |i|
      if (char = @chars[i]) == '\n'
        line += 1
        character = 0
      else
        character += self.class.code_units(char, position_encoding)
      end
    end

    LSProtocol::Position.new(
      line: line.to_u32,
      character: character.to_u32
    )
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

  def ameba_source : Ameba::Source
    @ameba_source ||= Ameba::Source.new(
      to_s,
      uri.path
    )
  end
end
