class Larimar::Parser
  struct Token
    include JSON::Serializable

    getter kind : TokenKind

    # Length of the trivia
    getter start : Int32

    # Length of the entire token
    getter length : Int32

    getter trivia_newline : Bool

    def initialize(@kind : TokenKind, @start, @length, @trivia_newline)
    end

    def text_length : Int32
      length - start
    end
  end
end
