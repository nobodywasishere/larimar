class Larimar::Parser
  struct Token
    include JSON::Serializable

    getter kind : TokenKind

    # Length of the trivia
    getter start : Int32

    # Length of the entire token
    getter length : Int32

    getter trivia_newline : Bool

    def initialize(
      @kind : TokenKind, @start = 0, @length = 0,
      @trivia_newline = false,
    )
    end

    def text_length : Int32
      length - start
    end

    def skipped
      Token.new(:VT_SKIPPED, start, length, trivia_newline)
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(@kind.to_s + " (#{length})")
    end
  end
end
