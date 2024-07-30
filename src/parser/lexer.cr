module Larimar::Parser
  class Lexer
    def self.lex(source : String) : {Array(Token), Array(Lexer::LexerError)}
      lexer = new(source)
      tokens = Array(Larimar::Parser::Token).new

      idx = 0
      loop do
        tokens << (token = lexer.next_token)
        break if token.kind.eof?

        idx += 1

        if idx > source.size
          puts "OVERFLOW #{idx}"
          pp token
          exit
        end
      end

      {tokens, lexer.errors}
    end

    record(LexerError, message : String, pos : Int32)

    getter reader : Char::Reader
    getter errors = Array(LexerError).new

    def initialize(source : String)
      @reader = Char::Reader.new(source)
    end

    def next_token : Larimar::Parser::Token
      full_start = @reader.pos

      # Capture whitespace and comments
      loop do
        case current_char
        when ' ', '\t', '\r'
          next_char
        when '\n'
          next_char
        when '#'
          until current_char.in?('\r', '\n', '\0')
            next_char
          end
        when '\0'
          start = @reader.pos
          return new_token(:EOF)
        else
          break
        end
      end

      start = @reader.pos
      # puts "fs: #{full_start}, s: #{start}, c: #{current_char}"

      case current_char
      when '\0'
        new_token(:EOF)
      when '='
        case next_char
        when '='
          if next_char == '='
            next_char
            new_token(:OP_EQ_EQ_EQ)
          else
            next_char
            new_token(:OP_EQ_EQ)
          end
        when '>'
          next_char
          new_token(:OP_EQ_GT)
        when '~'
          next_char
          new_token(:OP_EQ_TILDE)
        else
          new_token(:OP_EQ)
        end
      when '!'
        case next_char
        when '='
          next_char
          new_token(:OP_BANG_EQ)
        when '~'
          next_char
          new_token(:OP_BANG_TILDE)
        else
          new_token(:OP_BANG)
        end
      when '<'
        case next_char
        when '='
          case next_char
          when '>'
            next_char
            new_token(:OP_LT_EQ_GT)
          else
            new_token(:OP_LT_EQ)
          end
        when '<'
          case next_char
          when '='
            next_char
            new_token(:OP_LT_LT_EQ)
          when '-'
            if scan_heredoc_start
              new_token(:HEREDOC_START)
            else
              skip_to_valid
              new_token(:VT_SKIPPED)
            end
          else
            new_token(:OP_LT_LT)
          end
        else
          new_token(:OP_LT)
        end
      when '>'
        case next_char
        when '='
          next_char
          new_token(:OP_GT_EQ)
        when '>'
          case next_char
          when '='
            next_char
            new_token(:OP_GT_GT_EQ)
          else
            new_token(:OP_GT_GT)
          end
        else
          new_token(:OP_GT)
        end
      when '+'
        case next_char
        when '='
          next_char
          new_token(:OP_PLUS_EQ)
        when '+'
          next_char
          add_error("postfix increment is not supported, use `exp += 1`")
          new_token(:VT_SKIPPED)
        else
          new_token(:OP_PLUS)
        end
      when '-'
        case next_char
        when '='
          next_char
          new_token(:OP_MINUS_EQ)
        when '>'
          next_char
          new_token(:OP_MINUS_GT)
        when '-'
          next_char
          add_error("postfix decrement is not supported, use `exp -= 1`")
          new_token(:VT_SKIPPED)
        else
          new_token(:OP_MINUS)
        end
      when '*'
        case next_char
        when '='
          next_char
          new_token(:OP_STAR_EQ)
        when '*'
          case next_char
          when '='
            next_char
            new_token(:OP_STAR_STAR_EQ)
          else
            new_token(:OP_STAR_STAR)
          end
        else
          new_token(:OP_STAR)
        end
      when '/'
        case next_char
        when '/'
          case next_char
          when '='
            next_char
            new_token(:OP_SLASH_SLASH_EQ)
          else
            new_token(:OP_SLASH_SLASH)
          end
        when '='
          next_char
          new_token(:OP_SLASH_EQ)
        else
          new_token(:OP_SLASH)
        end
      when '%'
        case next_char
        when '='
          next_char
          new_token(:OP_PERCENT_EQ)
        when '}'
          next_char
          new_token(:OP_PERCENT_RCURLY)
        else
          new_token(:OP_PERCENT)
        end
      when '('
        next_char
        new_token(:OP_LPAREN)
      when ')'
        next_char
        new_token(:OP_RPAREN)
      when '{'
        case next_char
        when '%'
          next_char
          new_token(:OP_LCURLY_PERCENT)
        when '{'
          next_char
          new_token(:OP_LCURLY_LCURLY)
        else
          new_token(:OP_LCURLY)
        end
      when '}'
        next_char
        new_token(:OP_RCURLY)
      when '['
        case next_char
        when ']'
          case next_char
          when '='
            next_char
            new_token(:OP_LSQUARE_RSQUARE_EQ)
          when '?'
            next_char
            new_token(:OP_LSQUARE_RSQUARE_QUESTION)
          else
            new_token(:OP_LSQUARE)
          end
        else
          new_token(:OP_LSQUARE)
        end
      when ']'
        next_char
        new_token(:OP_RSQUARE)
      when ','
        next_char
        new_token(:OP_COMMA)
      when '?'
        next_char
        new_token(:OP_QUESTION)
      when ';'
        next_char
        new_token(:OP_SEMICOLON)
      when ':'
        if next_char == ':'
          next_char
          new_token(:OP_COLON_COLON)
        elsif false
          # consume_symbol
          new_token(:SYMBOL)
        else
          new_token(:OP_COLON)
        end
      when '~'
        next_char
        new_token(:OP_TILDE)
      when '.'
        case next_char
        when '.'
          case next_char
          when '.'
            new_token(:OP_PERIOD_PERIOD_PERIOD)
          else
            new_token(:OP_PERIOD_PERIOD)
          end
        when .ascii_number?
          add_error(".1 style number literal is not supported, put 0 before the dot")
          skip_to_valid
          new_token(:VT_SKIPPED)
        else
          new_token(:OP_PERIOD)
        end
      when '&'
        case next_char
        when '&'
          case next_char
          when '='
            next_char
            new_token(:OP_AMP_AMP_EQ)
          else
            new_token(:OP_AMP_AMP)
          end
        when '='
          next_char
          new_token(:OP_AMP_EQ)
        when '+'
          case next_char
          when '='
            next_char
            new_token(:OP_AMP_PLUS_EQ)
          else
            new_token(:OP_AMP_PLUS)
          end
        when '-'
          if next_char == '>'
            next_char
            new_token(:OP_AMP)
          else
            case next_char
            when '='
              next_char
              new_token(:OP_AMP_MINUS_EQ)
            else
              new_token(:OP_AMP_MINUS)
            end
          end
        when '*'
          case next_char
          when '*'
            next_char
            new_token(:OP_AMP_STAR_STAR)
          when '='
            next_char
            new_token(:OP_AMP_STAR_EQ)
          else
            new_token(:OP_AMP_STAR)
          end
        else
          new_token(:OP_AMP)
        end
      when '|'
        case next_char
        when '|'
          case next_char
          when '='
            next_char
            new_token(:OP_BAR_BAR_EQ)
          else
            new_token(:OP_BAR_BAR)
          end
        when '='
          next_char
          new_token(:OP_BAR_EQ)
        else
          new_token(:OP_BAR)
        end
      when '^'
        case next_char
        when '='
          next_char
          new_token(:OP_CARET_EQ)
        else
          new_token(:OP_CARET)
        end
      when '\''
        case next_char
        when '\\'
          case next_char
          when '\\', '\'', 'a', 'b', 'e', 'f', 'n', 'r', 't', 'v', '0'
            if next_char == '\''
              next_char
              new_token(:CHAR)
            else
              add_error("unterminated char literal, use double quotes for strings")
              skip_past('\'')
              next_char
              new_token(:VT_SKIPPED)
            end
          when 'u'
            skip_to_valid
            new_token(:VT_SKIPPED)
          when '\0'
            add_error("unterminated char literal")
            skip_to_valid
            new_token(:VT_SKIPPED)
          else
            add_error("invalid char escape sequence '\\#{current_char}'")
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        when '\''
          next_char
          add_error("invalid empty char literal (did you mean '\\''?)")
          new_token(:VT_SKIPPED)
        when '\0'
          next_char
          add_error("unterminated char literal")
          skip_past('\'')
          new_token(:VT_SKIPPED)
        else
          if next_char == '\''
            next_char
            new_token(:CHAR)
          else
            add_error("unterminated char literal, use double quotes for strings")
            skip_past('\'')
            next_char
            new_token(:VT_SKIPPED)
          end
        end
      when '0'..'9'
        if scan_number
          new_token(:NUMBER)
        else
          new_token(:VT_SKIPPED)
        end
      when '@'
        case next_char
        when '['
          next_char
          new_token(:OP_AT_LSQUARE)
        when '@'
          next_char
          if scan_ident
            new_token(:CLASS_VAR)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        else
          if scan_ident
            new_token(:INSTANCE_VAR)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        end
      when '$'
        case next_char
        when '~'
          next_char
          new_token(:OP_DOLLAR_TILDE)
        when '?'
          next_char
          new_token(:OP_DOLLAR_QUESTION)
        when .ascii_number?
          if current_char == '0'
            new_token(:GLOBAL_MATCH_DATA_INDEX)
          else
            while next_char.ascii_number?
            end

            if current_char == '?'
              next_char
            end

            new_token(:GLOBAL_MATCH_DATA_INDEX)
          end
        else
          if scan_ident
            new_token(:GLOBAL)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        end
      else
        if current_char.ascii_uppercase?
          while ident_part?
            next_char
          end

          new_token(:CONST)
        elsif ident_start?
          if scan_ident
            new_token(:IDENT)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        else
          skip_to_valid
          new_token(:VT_SKIPPED)
        end
      end
    end

    def scan_number : Bool?
      # puts "scanning number"

      base = 10
      is_decimal = false
      is_e_notation = false
      has_underscores = false
      last_is_underscore = false
      pos_before_exponent = nil

      if current_char == '0'
        case next_char
        when 'b' then base = 2
        when 'o' then base = 8
        when 'x' then base = 16
          # when '0'..'9'
          #   add_error("octal constants should be prefixed with 0o")
          #   skip_to_valid
          #   return
          # when '_'
          #   if next_char.in?('0'..'9')
          #     add_error("octal constants should be prefixed with 0o")
          #     skip_to_valid
          #     return
          #   end

          #   has_underscores = last_is_underscore = true
        end

        unless base == 10
          next_char

          # if current_char == '_'
          #   add_error("unexpected '_' in number")
          #   skip_to_valid
          #   return
          # end

          digit = String::CHAR_TO_DIGIT[current_char.ord]?
          if digit.nil? || digit.to_u8! >= base
            add_error("numeric literal without digits")
            skip_to_valid
            return
          end
        end
      end

      loop do
        loop do
          digit = String::CHAR_TO_DIGIT[current_char.ord]?
          break if digit.nil? || digit.to_u8! >= base

          next_char
          last_is_underscore = false
        end

        if pos_before_exponent && @reader.pos <= pos_before_exponent
          add_error("invalid decimal number exponent")
          skip_to_valid
          return
        end

        case current_char
        when '_'
          # if last_is_underscore
          #   add_error("consecutive underscores in numbers aren't allowed")
          #   skip_to_valid
          #   return
          # end

          # has_underscores = last_is_underscore = true
        when '.'
          # if last_is_underscore
          #   add_error("unexpected '_' in number")
          #   skip_to_valid
          #   return
          # end

          if is_decimal || base != 10 || !@reader.peek_next_char.in?('0'..'9')
            break
          end

          is_decimal = true
        when 'e', 'E'
          last_is_underscore = false

          if is_e_notation || base != 10
            break
          end

          is_e_notation = is_decimal = true

          if @reader.peek_next_char.in?('+', '-')
            next_char
          end

          # if @reader.peek_next_char == '_'
          #   add_error("unexpected '_' in number")
          #   skip_to_valid
          #   return
          # end

          pos_before_exponent = @reader.pos + 1
        when 'i', 'u', 'f'
          if current_char == 'f' && base != 10
            case base
            when 2
              add_error("binary float literal is not supported")
              skip_to_valid
              return
            when 8
              add_error("octal float literal is not supported")
              skip_to_valid
              return
            end

            break
          end

          scan_number_suffix

          next_char
          break
        else
          # if last_is_underscore
          #   add_error("trailing '_' in number")
          #   skip_to_valid
          #   return
          # end

          break
        end

        next_char
      end

      true
    end

    def scan_number_suffix : Bool?
      # puts "scanning number suffix"

      case current_char
      when 'i'
        case next_char
        when '8' then return
        when '1'
          case next_char
          when '2'
            next_char == '8'
          when '6'
            true
          end
        when '3'
          next_char == '2'
        when '6'
          next_char == '4'
        else
          add_error("invalid int suffix")
          false
        end
      when 'u'
        case next_char
        when '8'
          true
        when '1'
          case next_char
          when '2'
            next_char == '8'
          when '6'
            true
          end
        when '3'
          next_char == '2'
        when '6'
          next_char == '4'
        else
          add_error("invalid uint suffix")
          false
        end
      when 'f'
        case next_char
        when '3'
          next_char == '2'
        when '6'
          next_char == '4'
        else
          add_error("invalid float suffix")
          false
        end
      else
        add_error("BUG: invalid suffix")
        false
      end
    end

    def scan_heredoc_start : Bool?
      # puts "scanning heredoc start"

      next_char

      loop do
        case current_char
        when 'a'..'z', 'A'..'Z'
          next_char
        else
          break
        end
      end

      true
    end

    macro new_token(kind)
      Token.new(
        {{ kind }}, full_start, start,
        @reader.pos - full_start
      )
    end

    def add_error(message) : Nil
      @errors << LexerError.new(
        message, @reader.pos
      )
    end

    def skip_to_valid
      loop do
        case current_char
        when '\0', ' ', '\n', '\t'
          break
        else
          next_char
        end
      end
    end

    def skip_past(char : Char)
      while !current_char.in?(char, '\0')
        next_char
      end
    end

    def ident_start?(char = current_char)
      char.ascii_letter? || char == '_' || char.ord > 0x97
    end

    def ident_part?(char = current_char)
      ident_start?(char) || char.ascii_number?
    end

    def ident_part_or_end?(char = current_char)
      ident_part?(char) || char.in?('?', '!')
    end

    def scan_ident
      while ident_part?
        next_char
      end

      if current_char.in?('?', '!') && @reader.peek_next_char != '='
        next_char
      end

      true
    end

    macro scan_ident_token
      if scan_ident
        new_token(:IDENT)
      else
        skip_to_valid
        new_token(:VT_SKIPPED)
      end
    end

    def char_sequence?(*tokens : Char)
      tokens.all? do |token|
        token == next_char
      end
    end

    def check_ident_or_keyword(keyword : TokenKind) : TokenKind?
      if ident_part_or_end?(peek_next_char)
        if scan_ident
          TokenKind::IDENT
        else
          nil
        end
      else
        keyword
      end
    end

    def current_char
      @reader.current_char
    end

    def next_char
      @reader.next_char
    end

    def peek_next_char
      @reader.peek_next_char
    end
  end
end
