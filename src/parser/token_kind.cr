module Larimar::Parser
  enum TokenKind : UInt8
    EOF
    # SPACE
    # NEWLINE

    IDENT
    CONST
    INSTANCE_VAR
    CLASS_VAR

    CHAR
    STRING
    SYMBOL
    NUMBER

    UNDERSCORE
    COMMENT

    DELIMITER_START
    DELIMITER_END

    STRING_ARRAY_START
    INTERPOLATION_START
    SYMBOL_ARRAY_START
    STRING_ARRAY_END

    GLOBAL
    GLOBAL_MATCH_DATA_INDEX

    MAGIC_DIR
    MAGIC_END_LINE
    MAGIC_FILE
    MAGIC_LINE

    MACRO_LITERAL
    MACRO_EXPRESSION_START
    MACRO_CONTROL_START
    MACRO_VAR
    MACRO_END

    # the following operator kinds should be sorted by their codepoints
    # refer to `#to_s` for the constant names of each individual character

    OP_BANG                     # !
    OP_BANG_EQ                  # !=
    OP_BANG_TILDE               # !~
    OP_DOLLAR_QUESTION          # $?
    OP_DOLLAR_TILDE             # $~
    OP_PERCENT                  # %
    OP_PERCENT_EQ               # %=
    OP_PERCENT_RCURLY           # %}
    OP_AMP                      # &
    OP_AMP_AMP                  # &&
    OP_AMP_AMP_EQ               # &&=
    OP_AMP_STAR                 # &*
    OP_AMP_STAR_STAR            # &**
    OP_AMP_STAR_EQ              # &*=
    OP_AMP_PLUS                 # &+
    OP_AMP_PLUS_EQ              # &+=
    OP_AMP_MINUS                # &-
    OP_AMP_MINUS_EQ             # &-=
    OP_AMP_EQ                   # &=
    OP_LPAREN                   # (
    OP_RPAREN                   # )
    OP_STAR                     # *
    OP_STAR_STAR                # **
    OP_STAR_STAR_EQ             # **=
    OP_STAR_EQ                  # *=
    OP_PLUS                     # +
    OP_PLUS_EQ                  # +=
    OP_COMMA                    # ,
    OP_MINUS                    # -
    OP_MINUS_EQ                 # -=
    OP_MINUS_GT                 # ->
    OP_PERIOD                   # .
    OP_PERIOD_PERIOD            # ..
    OP_PERIOD_PERIOD_PERIOD     # ...
    OP_SLASH                    # /
    OP_SLASH_SLASH              # //
    OP_SLASH_SLASH_EQ           # //=
    OP_SLASH_EQ                 # /=
    OP_COLON                    # :
    OP_COLON_COLON              # ::
    OP_SEMICOLON                # ;
    OP_LT                       # <
    OP_LT_LT                    # <<
    OP_LT_LT_EQ                 # <<=
    OP_LT_EQ                    # <=
    OP_LT_EQ_GT                 # <=>
    OP_EQ                       # =
    OP_EQ_EQ                    # ==
    OP_EQ_EQ_EQ                 # ===
    OP_EQ_GT                    # =>
    OP_EQ_TILDE                 # =~
    OP_GT                       # >
    OP_GT_EQ                    # >=
    OP_GT_GT                    # >>
    OP_GT_GT_EQ                 # >>=
    OP_QUESTION                 # ?
    OP_AT_LSQUARE               # @[
    OP_LSQUARE                  # [
    OP_LSQUARE_RSQUARE          # []
    OP_LSQUARE_RSQUARE_EQ       # []=
    OP_LSQUARE_RSQUARE_QUESTION # []?
    OP_RSQUARE                  # ]
    OP_CARET                    # ^
    OP_CARET_EQ                 # ^=
    OP_GRAVE                    # `
    OP_LCURLY                   # {
    OP_LCURLY_PERCENT           # {%
    OP_LCURLY_LCURLY            # {{
    OP_BAR                      # |
    OP_BAR_EQ                   # |=
    OP_BAR_BAR                  # ||
    OP_BAR_BAR_EQ               # ||=
    OP_RCURLY                   # }
    OP_TILDE                    # ~

    VT_MISSING
    VT_SKIPPED

    HEREDOC_START
    HEREDOC_BODY

    # keywords

    KW_ABSTRACT
    KW_ALIAS
    KW_ALIGNOF
    KW_ANNOTATION
    KW_AS
    KW_AS_QUESTION
    KW_ASM
    KW_BEGIN
    KW_BREAK
    KW_CASE
    KW_CLASS
    KW_DEF
    KW_DO
    KW_ELSE
    KW_ELSIF
    KW_END
    KW_ENSURE
    KW_ENUM
    KW_EXTEND
    KW_FALSE
    KW_FOR
    KW_FUN
    KW_IF
    KW_IN
    KW_INCLUDE
    KW_INSTANCE_ALIGNOF
    KW_INSTANCE_SIZEOF
    KW_IS_A_QUESTION
    KW_LIB
    KW_MACRO
    KW_MODULE
    KW_NEXT
    KW_NIL
    KW_NIL_QUESTION
    KW_OF
    KW_OFFSETOF
    KW_OUT
    KW_POINTEROF
    KW_PRIVATE
    KW_PROTECTED
    KW_REQUIRE
    KW_RESCUE
    KW_RESPONDS_TO_QUESTION
    KW_RETURN
    KW_SELECT
    KW_SELF
    KW_SIZEOF
    KW_STRUCT
    KW_SUPER
    KW_THEN
    KW_TRUE
    KW_TYPE
    KW_TYPEOF
    KW_UNINITIALIZED
    KW_UNION
    KW_UNLESS
    KW_UNTIL
    KW_VERBATIM
    KW_WHEN
    KW_WHILE
    KW_WITH
    KW_YIELD

    # # non-flag enums are special since the `IO` overload relies on the
    # # `String`-returning overload instead of the other way round
    # def to_s : String
    #   {% begin %}
    #     {%
    #       operator1 = {
    #         "BANG" => "!", "DOLLAR" => "$", "PERCENT" => "%", "AMP" => "&", "LPAREN" => "(",
    #         "RPAREN" => ")", "STAR" => "*", "PLUS" => "+", "COMMA" => ",", "MINUS" => "-",
    #         "PERIOD" => ".", "SLASH" => "/", "COLON" => ":", "SEMICOLON" => ";", "LT" => "<",
    #         "EQ" => "=", "GT" => ">", "QUESTION" => "?", "AT" => "@", "LSQUARE" => "[",
    #         "RSQUARE" => "]", "CARET" => "^", "GRAVE" => "`", "LCURLY" => "{", "BAR" => "|",
    #         "RCURLY" => "}", "TILDE" => "~",
    #       }
    #     %}

    #     case self
    #     {% for member in @type.constants %}
    #     in {{ member.id }}
    #       {% if member.starts_with?("OP_") %}
    #         {% parts = member.split("_") %}
    #         {{ parts.map { |ch| operator1[ch] || "" }.join("") }}
    #       {% elsif member.starts_with?("MAGIC_") %}
    #         {{ "__#{member[6..-1].id}__" }}
    #       {% else %}
    #         {{ member.stringify }}
    #       {% end %}
    #     {% end %}
    #     end
    #   {% end %}
    # end
  end
end
