module Larimar::Parser
  struct Token
    include JSON::Serializable

    getter kind : TokenKind
    getter full_start : Int32
    getter start : Int32
    getter length : Int32

    def initialize(@kind : TokenKind, @full_start, @start, @length)
    end

    def trivia(document : Document) : String
      document.slice(full_start, start)
    end

    def text(document : Document) : String
      document.slice(start, start + length)
    end

    def text_length : Int32
      length + full_start - start
    end

    def full_text(document : Document) : String
      document.slice(full_start, start + length)
    end
  end
end
