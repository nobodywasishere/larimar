module Larimar::Parser
  struct Token
    include JSON::Serializable

    getter kind : TokenKind

    # Length of the trivia
    getter start : Int32

    # Length of the entire token
    getter length : Int32

    def initialize(@kind : TokenKind, @start, @length)
    end

    def text_length : Int32
      length - start
    end
  end
end
