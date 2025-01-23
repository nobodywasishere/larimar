class Larimar::TextDocument
  Log = ::Larimar::Log.for(self)

  @chars : Array(Char)

  getter uri : URI
  getter version : Int32
  getter mutex : RWLock = RWLock.new

  def initialize(document : String, @uri : URI, @version : Int32 = 0)
    @chars = document.encode("UTF-8").map(&.unsafe_chr).to_a
  end

  def update_partial(range : LSProtocol::Range, text : String, version : Int32 = 0) : Nil
    @ameba_source = nil
    start_pos = position_to_index(range.start)
    end_pos = position_to_index(range.end)

    @chars[start_pos...end_pos] = text.encode("UTF-8").map(&.unsafe_chr).to_a
    @version = version
  end

  def update_whole(text : String, version : Int32 = 0) : Nil
    @ameba_source = nil
    @chars = text.encode("UTF-8").map(&.unsafe_chr).to_a
    @version = version
  end

  def to_s(io : IO)
    @chars.each do |char|
      io << char
    end
  end

  def to_s : String
    mem = IO::Memory.new

    to_s(mem)

    mem.to_s
  end

  def position_to_index(position : LSProtocol::Position) : Int32
    line = 0
    colm = 0
    posi = 0

    if position.line == line && position.character == colm
      return posi
    end

    @chars.each do |char|
      case char
      when '\n'
        line += 1
        colm = 0
      else
        colm += 1
      end

      posi += 1

      if position.line == line && position.character == colm
        return posi
      end
    end

    raise IndexError.new("#{position.line},#{position.character} not in document")
  end

  def index_to_position(index : Int32) : LSProtocol::Position
    line = 0
    colm = 0
    posi = 0

    if posi == index
      return LSProtocol::Position.new(
        line: line.to_u32,
        character: colm.to_u32
      )
    end

    @chars.each do |char|
      case char
      when '\n'
        line += 1
        colm = 0
      else
        colm += 1
      end

      posi += 1

      if posi == index
        return LSProtocol::Position.new(
          line: line.to_u32,
          character: colm.to_u32
        )
      end
    end

    raise IndexError.new("#{index} not in document")
  end

  @ameba_source : Ameba::Source?

  def ameba_source : Ameba::Source
    @ameba_source ||= Ameba::Source.new(
      self.to_s,
      self.uri.path
    )
  end
end
