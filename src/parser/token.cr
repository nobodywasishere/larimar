module Larimar::Parser
  struct Token
    include JSON::Serializable

    getter kind : TokenKind
    getter full_start : Int32
    getter start : Int32
    getter length : Int32

    def initialize(@kind : TokenKind, @full_start, @start, @length)
    end

    def trivia(document : String) : String
      document.byte_slice(full_start, start)
    end

    def text(document : String)
      document.byte_slice(start, start + length)
    end

    def full_text(document : String)
      document.byte_slice(full_start, start + length)
    end
  end
end
