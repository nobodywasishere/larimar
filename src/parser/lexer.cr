class Larimar::Parser
  class Lexer
    Log = ::Larimar::Log.for(self)

    def self.lex_full(document : Document) : Nil
      document.seek_to(0)

      lexer = new(document)
      tokens = Array(Larimar::Parser::Token).new

      idx = 0
      loop do
        tokens << (token = lexer.next_token)
        break if token.kind.eof? || document.eof?

        idx += 1

        if idx > document.size
          Log.error { "OVERFLOW #{idx}\n#{tokens}" }
        end
      end

      if tokens.empty? || !tokens.last.kind.eof?
        tokens << Token.new(:EOF, 0, 0, false)
      end

      document.tokens = tokens
      document.lex_errors = lexer.errors
    end

    def self.lex_partial(document : Document, range : LSProtocol::Range, edit_size : Int32) : Nil
      lexer = new(document)
      tokens = document.tokens

      # find start index of first overlapping token
      change_start_idx = document.position_to_index(range.start)

      char_start_idx = 0
      token_start_idx = 0
      doc_idx = 0

      # find end index of last overlapping token
      tokens.each_with_index do |token, token_idx|
        if doc_idx < change_start_idx
          char_start_idx = doc_idx
          token_start_idx = token_idx
        end

        doc_idx += token.length
      end

      # remove any relevant errors
      # document.lex_errors.reject! { |e| char_start_idx <= e.pos && e.pos <= char_end_idx }

      # seek document to the start index
      document.seek_to(char_start_idx)
      new_tokens = Array(Token).new

      doc_idx = char_start_idx
      doc_token_idx = doc_idx

      token_end_idx = 0

      loop do
        new_tokens << (token = lexer.next_token)

        if token.kind.eof? || document.eof?
          token_end_idx = tokens.size
          break
        end

        doc_idx += token.length

        # if (char_start_idx + edit_size) > doc_idx

        # end
      end

      tokens[token_start_idx...token_end_idx] = new_tokens
      document.tokens = tokens
    end

    record(LexerError, message : String, pos : Int32)

    getter reader : Document
    getter errors = Array(LexerError).new

    @wants_symbol = true

    def initialize(@reader : Parser::Document)
    end

    def next_token : Larimar::Parser::Token
      full_start = @reader.pos
      trivia_newline = false

      # Capture whitespace and comments
      loop do
        case current_char
        when ' ', '\t', '\r'
          next_char
        when '\n', ';'
          trivia_newline = true
          next_char
        when '#'
          until current_char.in?('\r', '\n', '\0')
            next_char
          end
        when '\0'
          start = @reader.pos
          return new_token(TokenKind::EOF)
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
            new_token(:OP_LSQUARE_RSQUARE)
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
        # when ';'
        #   next_char
        #   new_token(:OP_SEMICOLON)
      when ':'
        if peek_next_char == ':'
          next_char
          next_char
          new_token(:OP_COLON_COLON)
        elsif @wants_symbol
          if token = scan_symbol
            new_token(token)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
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
            next_char
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
            add_error("unicode chars currently not supported")
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
      when '"'
        next_char
        skip_past('"')
        next_char
        new_token(:STRING)
      when '`'
        next_char
        skip_past('`')
        next_char
        new_token(:OP_GRAVE)
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
            next_char
            new_token(:GLOBAL_MATCH_DATA_INDEX)
          else
            while next_char.ascii_number?
            end

            if current_char == '?'
              next_char
            end

            next_char
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
      when 'a'
        case next_char
        when 'b'
          check_keyword_sequence(['s', 't', 'r', 'a', 'c', 't'], :KW_ABSTRACT)
        when 'l'
          if next_char == 'i'
            case next_char
            when 'a'
              check_keyword_sequence(['s'], :KW_ALIAS)
            when 'g'
              check_keyword_sequence(['n', 'o', 'f'], :KW_ALIGNOF)
            else
              scan_ident_token
            end
          else
            scan_ident_token
          end
        when 's'
          case peek_next_char
          when 'm'
            next_char
            if token = check_ident_or_keyword(:KW_ASM)
              new_token(token)
            else
              skip_to_valid
              new_token(:VT_SKIPPED)
            end
          when '?'
            next_char
            next_char
            new_token(:KW_AS_QUESTION)
          else
            if token = check_ident_or_keyword(:KW_AS)
              new_token(token)
            else
              skip_to_valid
              new_token(:VT_SKIPPED)
            end
          end
        when 'n'
          check_keyword_sequence(['n', 'o', 't', 'a', 't', 'i', 'o', 'n'], :KW_ANNOTATION)
        else
          scan_ident_token
        end
      when 'b'
        case next_char
        when 'e'
          check_keyword_sequence(['g', 'i', 'n'], :KW_BEGIN)
        when 'r'
          check_keyword_sequence(['e', 'a', 'k'], :KW_BREAK)
        else
          scan_ident_token
        end
      when 'c'
        case next_char
        when 'a'
          check_keyword_sequence(['s', 'e'], :KW_CASE)
        when 'l'
          check_keyword_sequence(['a', 's', 's'], :KW_CLASS)
        else
          scan_ident_token
        end
      when 'd'
        case next_char
        when 'e'
          check_keyword_sequence(['f'], :KW_DEF)
        when 'o'
          if token = check_ident_or_keyword(:KW_DO)
            new_token(token)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        else
          scan_ident_token
        end
      when 'e'
        case next_char
        when 'l'
          case next_char
          when 's'
            case next_char
            when 'e'
              if token = check_ident_or_keyword(:KW_ELSE)
                new_token(token)
              else
                skip_to_valid
                new_token(:VT_SKIPPED)
              end
            when 'i'
              check_keyword_sequence(['f'], :KW_ELSIF)
            else
              scan_ident_token
            end
          else
            scan_ident_token
          end
        when 'n'
          case next_char
          when 'd'
            if token = check_ident_or_keyword(:KW_END)
              new_token(token)
            else
              skip_to_valid
              new_token(:VT_SKIPPED)
            end
          when 's'
            check_keyword_sequence(['u', 'r', 'e'], :KW_ENSURE)
          when 'u'
            check_keyword_sequence(['m'], :KW_ENUM)
          else
            scan_ident_token
          end
        when 'x'
          check_keyword_sequence(['t', 'e', 'n', 'd'], :KW_ENSURE)
        else
          scan_ident_token
        end
      when 'f'
        case next_char
        when 'a'
          check_keyword_sequence(['l', 's', 'e'], :KW_FALSE)
        when 'o'
          if next_char == 'r'
            if peek_next_char == 'a'
              next_char
              check_keyword_sequence(['l', 'l'], :KW_FORALL)
            elsif token = check_ident_or_keyword(:KW_FOR)
              new_token(token)
            else
              skip_to_valid
              new_token(:VT_SKIPPED)
            end
          else
            scan_ident_token
          end
        when 'u'
          check_keyword_sequence(['n'], :KW_FUN)
        else
          scan_ident_token
        end
      when 'i'
        case next_char
        when 'f'
          if token = check_ident_or_keyword(:KW_IF)
            new_token(token)
          else
            skip_to_valid
            new_token(:VT_SKIPPED)
          end
        when 'n'
          if ident_part_or_end?(peek_next_char)
            case next_char
            when 'c'
              check_keyword_sequence(['l', 'u', 'd', 'e'], :KW_INCLUDE)
            when 's'
              if char_sequence?('t', 'a', 'n', 'c', 'e', '_')
                case next_char
                when 's'
                  check_keyword_sequence(['i', 'z', 'e', 'o', 'f'], :KW_INSTANCE_SIZEOF)
                when 'a'
                  check_keyword_sequence(['l', 'i', 'g', 'n', 'o', 'f'], :KW_INSTANCE_ALIGNOF)
                else
                  scan_ident_token
                end
              else
                scan_ident_token
              end
            else
              scan_ident_token
            end
          else
            scan_ident_token
          end
        when 's'
          check_keyword_sequence(['_', 'a', '?'], :KW_IS_A_QUESTION)
        else
          scan_ident_token
        end
      when 'l'
        case next_char
        when 'i'
          check_keyword_sequence(['b'], :KW_LIB)
        else
          scan_ident_token
        end
      when 'm'
        case next_char
        when 'a'
          check_keyword_sequence(['c', 'r', 'o'], :KW_MACRO)
        when 'o'
          check_keyword_sequence(['d', 'u', 'l', 'e'], :KW_MODULE)
        else
          scan_ident_token
        end
      when 'n'
        case next_char
        when 'e'
          check_keyword_sequence(['x', 't'], :KW_NEXT)
        when 'i'
          case next_char
          when 'l'
            if peek_next_char == '?'
              next_char
              next_char
              new_token(:KW_NIL_QUESTION)
            else
              if token = check_ident_or_keyword(:KW_NIL)
                new_token(token)
              else
                skip_to_valid
                new_token(:VT_SKIPPED)
              end
            end
          else
            scan_ident_token
          end
        else
          scan_ident_token
        end
      when 'o'
        case next_char
        when 'f'
          if peek_next_char == 'f'
            next_char
            check_keyword_sequence(['s', 'e', 't', 'o', 'f'], :KW_OFFSETOF)
          else
            if token = check_ident_or_keyword(:KW_OF)
              new_token(token)
            else
              skip_to_valid
              new_token(:VT_SKIPPED)
            end
          end
        when 'u'
          check_keyword_sequence(['t'], :KW_OUT)
        else
          scan_ident_token
        end
      when 'p'
        case next_char
        when 'o'
          check_keyword_sequence(['i', 'n', 't', 'e', 'r', 'o', 'f'], :KW_POINTEROF)
        when 'r'
          case next_char
          when 'i'
            check_keyword_sequence(['v', 'a', 't', 'e'], :KW_PRIVATE)
          when 'o'
            check_keyword_sequence(['t', 'e', 'c', 't', 'e', 'd'], :KW_PROTECTED)
          else
            scan_ident_token
          end
        else
          scan_ident_token
        end
      when 'r'
        case next_char
        when 'e'
          case next_char
          when 's'
            case next_char
            when 'c'
              check_keyword_sequence(['u', 'e'], :KW_RESCUE)
            when 'p'
              check_keyword_sequence(['o', 'n', 'd', 's', '_', 't', 'o', '?'], :KW_RESPONDS_TO_QUESTION)
            else
              scan_ident_token
            end
          when 't'
            check_keyword_sequence(['u', 'r', 'n'], :KW_RETURN)
          when 'q'
            check_keyword_sequence(['u', 'i', 'r', 'e'], :KW_REQUIRE)
          else
            scan_ident_token
          end
        else
          scan_ident_token
        end
      when 's'
        case next_char
        when 'e'
          if next_char == 'l'
            case next_char
            when 'e'
              check_keyword_sequence(['c', 't'], :KW_SELECT)
            when 'f'
              if token = check_ident_or_keyword(:KW_SELF)
                new_token(token)
              else
                skip_to_valid
                new_token(:VT_SKIPPED)
              end
            else
              scan_ident_token
            end
          else
            scan_ident_token
          end
        when 'i'
          check_keyword_sequence(['z', 'e', 'o', 'f'], :KW_SIZEOF)
        when 't'
          check_keyword_sequence(['r', 'u', 'c', 't'], :KW_STRUCT)
        when 'u'
          check_keyword_sequence(['p', 'e', 'r'], :KW_SUPER)
        else
          scan_ident_token
        end
      when 't'
        case next_char
        when 'h'
          check_keyword_sequence(['e', 'n'], :KW_THEN)
        when 'r'
          check_keyword_sequence(['u', 'e'], :KW_TRUE)
        when 'y'
          check_keyword_sequence(['p', 'e', 'o', 'f'], :KW_TYPEOF)
        else
          scan_ident_token
        end
      when 'u'
        case next_char
        when 'n'
          case next_char
          when 'i'
            case next_char
            when 'o'
              check_keyword_sequence(['n'], :KW_UNION)
            when 'n'
              check_keyword_sequence(['i', 't', 'i', 'a', 'l', 'i', 'z', 'e', 'd'], :KW_UNINITIALIZED)
            else
              scan_ident_token
            end
          when 'l'
            check_keyword_sequence(['e', 's', 's'], :KW_UNLESS)
          when 't'
            check_keyword_sequence(['i', 'l'], :KW_UNTIL)
          else
            scan_ident_token
          end
        else
          scan_ident_token
        end
      when 'v'
        check_keyword_sequence(['e', 'r', 'b', 'a', 't', 'i', 'm'], :KW_VERBATIM)
      when 'w'
        case next_char
        when 'h'
          case next_char
          when 'e'
            check_keyword_sequence(['n'], :KW_WHEN)
          when 'i'
            check_keyword_sequence(['l', 'e'], :KW_WHILE)
          else
            scan_ident_token
          end
        when 'i'
          check_keyword_sequence(['t', 'h'], :KW_WITH)
        else
          scan_ident_token
        end
      when 'y'
        check_keyword_sequence(['i', 'e', 'l', 'd'], :KW_YIELD)
      when '_'
        case next_char
        when '_'
          case next_char
          when 'D'
            check_keyword_sequence(['I', 'R', '_', '_'], :MAGIC_DIR)
          when 'E'
            check_keyword_sequence(['N', 'D', '_', 'L', 'I', 'N', 'E', '_', '_'], :MAGIC_END_LINE)
          when 'F'
            check_keyword_sequence(['I', 'L', 'E', '_', '_'], :MAGIC_FILE)
          when 'L'
            check_keyword_sequence(['I', 'N', 'E', '_', '_'], :MAGIC_LINE)
          else
            scan_ident_token
          end
        else
          unless ident_part?
            new_token(:UNDERSCORE)
          else
            scan_ident_token
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
    rescue ex
      Log.error(exception: ex) { "Error when lexing next token: #{ex.message}\n#{ex.backtrace.join("\n")}" }
      add_error(ex.message || "Error when lexing")

      full_start = full_start.not_nil!
      trivia_newline = trivia_newline.nil? ? false : trivia_newline

      if start
        new_token(TokenKind::VT_SKIPPED)
      else
        Token.new(
          :VT_SKIPPED, @reader.pos - full_start,
          @reader.pos - full_start, trivia_newline
        )
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
        when '0'..'9'
          add_error("octal constants should be prefixed with 0o")
          skip_to_valid
          return
        when '_'
          if next_char.in?('0'..'9')
            add_error("octal constants should be prefixed with 0o")
            skip_to_valid
            return
          end

          has_underscores = last_is_underscore = true
        end

        unless base == 10
          next_char

          if current_char == '_'
            add_error("unexpected '_' in number")
            skip_to_valid
            return
          end

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
          if last_is_underscore
            add_error("consecutive underscores in numbers aren't allowed")
            skip_to_valid
            return
          end

          has_underscores = last_is_underscore = true
        when '.'
          if last_is_underscore
            add_error("unexpected '_' in number")
            skip_to_valid
            return
          end

          if is_decimal || base != 10 || !peek_next_char.in?('0'..'9')
            break
          end

          is_decimal = true
        when 'e', 'E'
          last_is_underscore = false

          if is_e_notation || base != 10
            break
          end

          is_e_notation = is_decimal = true

          if peek_next_char.in?('+', '-')
            next_char
          end

          if peek_next_char == '_'
            add_error("unexpected '_' in number")
            skip_to_valid
            return
          end

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

          if !scan_number_suffix
            skip_to_valid
            return
          end

          next_char
          break
        else
          if last_is_underscore
            add_error("trailing '_' in number")
            skip_to_valid
            return
          end

          break
        end

        next_char
      end

      true
    end

    def scan_number_suffix : Bool?
      case current_char
      when 'i'
        case next_char
        when '8' then return
        when '1'
          case next_char
          when '2'
            next_char == '8' || add_error("invalid int suffix")
          when '6'
            true
          end
        when '3'
          next_char == '2' || add_error("invalid int suffix")
        when '6'
          next_char == '4' || add_error("invalid int suffix")
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
            next_char == '8' || add_error("invalid uint suffix")
          when '6'
            true
          end
        when '3'
          next_char == '2' || add_error("invalid uint suffix")
        when '6'
          next_char == '4' || add_error("invalid uint suffix")
        else
          add_error("invalid uint suffix")
          false
        end
      when 'f'
        case next_char
        when '3'
          next_char == '2' || add_error("invalid float suffix")
        when '6'
          next_char == '4' || add_error("invalid float suffix")
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
        {{ kind }}, start - full_start,
        @reader.pos - full_start, trivia_newline
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

      if current_char.in?('?', '!') && peek_next_char != '='
        next_char
      end

      true
    end

    macro check_keyword_sequence(chars, token)
      if char_sequence?({{ chars.splat }})
        if current_char.in?('?', '!')
          next_char
          new_token({{ token }})
        elsif token = check_ident_or_keyword({{ token }})
          new_token(token)
        else
          skip_to_valid
          new_token(:VT_SKIPPED)
        end
      else
        scan_ident_token
      end
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
        next_char
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

    def scan_symbol : TokenKind?
      case next_char
      when ':'
        next_char
        TokenKind::OP_COLON_COLON
      when '+', '-', '|', '^', '~', '%'
        next_char
        TokenKind::SYMBOL
      when '*'
        case next_char
        when '*'
          next_char
          TokenKind::SYMBOL
        else
          TokenKind::SYMBOL
        end
      when '/'
        case next_char
        when '/'
          next_char
          TokenKind::SYMBOL
        else
          TokenKind::SYMBOL
        end
      when '='
        case next_char
        when '='
          if next_char == '='
            next_char
            TokenKind::SYMBOL
          else
            TokenKind::SYMBOL
          end
        when '~'
          next_char
          TokenKind::SYMBOL
        else
          add_error("Unknown symbol")
          nil
        end
      when '!'
        case next_char
        when '='
          next_char
          TokenKind::SYMBOL
        when '~'
          next_char
          TokenKind::SYMBOL
        else
          TokenKind::SYMBOL
        end
      when '<'
        case next_char
        when '='
          if next_char == '>'
            next_char
            TokenKind::SYMBOL
          else
            TokenKind::SYMBOL
          end
        when '<'
          next_char
          TokenKind::SYMBOL
        else
          TokenKind::SYMBOL
        end
      when '>'
        case next_char
        when '='
          next_char
          TokenKind::SYMBOL
        when '>'
          next_char
          TokenKind::SYMBOL
        else
          TokenKind::SYMBOL
        end
      when '&'
        case next_char
        when '+'
          next_char
          TokenKind::SYMBOL
        when '-'
          next_char
          TokenKind::SYMBOL
        when '*'
          case next_char
          when '*'
            next_char
            TokenKind::SYMBOL
          else
            TokenKind::SYMBOL
          end
        else
          TokenKind::SYMBOL
        end
      when '['
        if next_char == ']'
          case next_char
          when '='
            next_char
            TokenKind::SYMBOL
          when '?'
            next_char
            TokenKind::SYMBOL
          else
            TokenKind::SYMBOL
          end
        else
          add_error("Unknown symbol")
          nil
        end
      when '"'
        next_char
        skip_past('"')
        next_char
        TokenKind::SYMBOL
      else
        if ident_start?
          if scan_ident
            TokenKind::SYMBOL
          else
            nil
          end
        else
          TokenKind::OP_COLON
        end
      end
    end
  end
end
