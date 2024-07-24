class Larimar::TextDocument
  getter uri : URI
  @inner_contents : Array(String) = Array(String).new

  def initialize(@uri : URI, contents : String)
    self.contents = contents
  end

  def contents : String
    @inner_contents.join
  end

  def line_count : UInt32
    @inner_contents.size.to_u32
  end

  def contents=(contents : String)
    @inner_contents = contents.lines(chomp: false)
  end

  def update_contents(changes : Array(LSProtocol::TextDocumentContentChangeEvent))
    changes.each do |change|
      update_contents(change)
    end
  end

  def update_contents(change : LSProtocol::TextDocumentContentChangePartial)
    text = change.text
    range = change.range

    prefix = @inner_contents[range.start.line]?.try(&.[...range.start.character].chomp) || ""
    suffix = @inner_contents[range.end.line]?.try(&.[range.end.character..]?) ||
             @inner_contents[range.end.line]? || ""

    Log.info { "Prefix: #{prefix}" }
    Log.info { "Suffix: #{suffix}" }

    change_lines = String.build do |b|
      b << prefix
      b << change.text
      b << suffix
    end.lines(chomp: false)

    @inner_contents = (@inner_contents[...range.start.line]? || [] of String) +
                      change_lines +
                      (@inner_contents[range.end.line + 1...]? || [] of String)
  end

  def update_contents(change : LSProtocol::TextDocumentContentChangeWholeDocument)
    self.contents = change.text
  end
end
