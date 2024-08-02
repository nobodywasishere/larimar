class Larimar::Parser::Document
  Log = ::Larimar::Log.for(self)

  @chars : Array(Char)

  # Current character position within the document
  getter pos : Int32
  getter version : Int32
  getter mutex : Mutex = Mutex.new

  property tokens : Array(Token) = Array(Token).new
  property semantic_tokens : Array(SemanticTokensVisitor::SemanticToken) = Array(SemanticTokensVisitor::SemanticToken).new
  property lex_errors : Array(Lexer::LexerError) = Array(Lexer::LexerError).new
  property diagnostics : Array(LSProtocol::Diagnostic) = Array(LSProtocol::Diagnostic).new

  def initialize(document : String, version : Int32 = 0)
    @chars = document.chars
    @pos = 0
    @version = version
  end

  def current_char : Char
    if @chars.size == @pos
      return '\0'
    end

    @chars[@pos]
  end

  def next_char : Char
    @pos += 1

    current_char
  end

  def peek_next_char : Char
    if @chars.size == @pos + 1
      return '\0'
    end

    @chars[@pos + 1]
  end

  def update_partial(range : LSProtocol::Range, text : String, version : Int32 = 0) : Nil
    start_pos = position_to_index(range.start)
    end_pos = position_to_index(range.end)

    @chars[start_pos...end_pos] = text.chars
    @pos = 0
    @version = version
  end

  def update_whole(text : String, version : Int32 = 0)
    @chars = text.chars
    @pos = 0
    @version = version
  end

  def eof?
    @chars.size <= @pos
  end

  def seek_to(pos : Int32)
    @pos = pos
  end

  def to_s(io : IO)
    @chars.each do |char|
      io << char
    end
  end

  # Zero-indexed slice of the document
  def slice(start : Int32, length : Int32) : String
    @chars[start...(start + length)].join
  end

  def size
    @chars.size
  end

  def line_count
    @chars.count('\n')
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
end
