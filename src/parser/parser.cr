class Larimar::Parser
  Log = ::Larimar::Log.for(self)

  record(ParserError, message : String, pos : Int32)

  getter tokens : Array(Token)
  getter errors = Array(ParserError).new

  @tokens_idx = 0
  @doc_idx = 0

  def self.parse_full(document : Document) : Nil
    Lexer.lex_full(document)

    document.seek_to(0)

    parser = new(document)

    document.ast = parser.parse
    document.parse_errors = parser.errors
  end

  def initialize(@tokens)
    @doc_idx = tokens[0]?.try(&.start) || 0
  end

  def parse : AST::Node
    parse_expressions
  end

  def parse_expressions : AST::Node
    node = AST::Expressions.new([] of AST::Node)

    if end_token?
      node.children << AST::Nop.new
      return node
    end

    loop do
      node.children << parse_multi_assign
      break if end_token?
    end

    node
  end

  def parse_multi_assign : AST::Node
    # TODO: stuff
    parse_expression
  end

  def parse_expression : AST::Node
    # TODO: stuff
    parse_op_assign
  end

  def parse_op_assign : AST::Node
    # TODO: stuff
    parse_question_colon
  end

  def parse_question_colon : AST::Node
    cond = parse_range

    while current_token.kind.op_question?
      question = consume(:OP_QUESTION)
      true_case = parse_question_colon
      colon = consume(:OP_COLON)
      false_case = parse_question_colon

      cond = AST::Ternary.new(cond, question, true_case, colon, false_case)
    end

    cond
  end

  def parse_range : AST::Node
    if current_token.kind.op_period_period? || current_token.kind.op_period_period_period?
      expression = AST::Nop.new
    else
      expression = parse_or
    end

    loop do
      case current_token.kind
      when .op_period_period?, .op_period_period_period?
        expression = new_range(expression)
      else
        break
      end
    end

    expression
  end

  def new_range(expression) : AST::Node
    dots = current_token
    next_token

    kind = current_token.kind
    if end_token? || kind.op_rparen? || kind.op_comma? || kind.op_eq_gt? ||
        kind.op_semicolon? || current_token.trivia_newline
      right = AST::Nop.new
    else
      right = parse_or
    end

    AST::RangeLiteral.new(expression, dots, right)
  end

  macro parse_operator(name, next_operator, node, *operators, right_associative = false)
    def parse_{{ name.id }} : AST::Node
      left = parse_{{ next_operator.id }}

      while true
        case current_token.kind
        when {{ operators.map { |op| ".#{op.id}".id }.splat }}
          operator = current_token
          next_token

          right = parse_{{ (right_associative ? name : next_operator) }}
          left = {{ node.id }}
        else
          return left
        end
      end
    end
  end

  parse_operator or, and, "AST::Or.new left, operator, right", :op_bar_bar?
  parse_operator and, equality, "AST::And.new left, operator, right", :op_amp_amp?
  parse_operator equality, cmp, "AST::Call.new left, operator, right", :op_lt?, :op_lt_eq?, :op_gt?, :op_gt_eq?, :op_lt_eq_gt?
  parse_operator cmp, logical_or, "AST::Call.new left, operator, right", :op_eq_eq?, :op_bang_eq?, :op_eq_tilde?, :op_bang_tilde?, :op_eq_eq_eq?
  parse_operator logical_or, logical_and, "AST::Call.new left, operator, right", :op_bar?, :op_caret?
  parse_operator logical_and, shift, "AST::Call.new left, operator, right", :op_amp?
  parse_operator shift, add_or_sub, "AST::Call.new left, operator, right", :op_lt_lt?, :op_gt_gt?

  def parse_add_or_sub : AST::Node
    left = parse_mul_or_div

    while true
      case current_token.kind
      when .op_plus?, .op_minus?, .op_amp_plus?, .op_amp_minus?
        operator = current_token
        next_token

        right = parse_mul_or_div

        left = AST::Call.new left, operator, right
      # when .number?
      # TODO: stuff
      else
        return left
      end
    end
  end

  parse_operator mul_or_div, pow, "AST::Call.new left, operator, right", :op_star?, :op_slash?, :op_slash_slash?, :op_percent?, :op_amp_star?
  parse_operator pow, prefix, "AST::Call.new left, operator, right", :op_star_star?, :op_amp_star_star?, right_associative: true

  def parse_prefix : AST::Node
    case current_token.kind
    when .unary_operator?
      operator = current_token
      next_token

      arg = parse_prefix

      if operator.kind.op_bang?
        AST::Not.new(arg, operator)
      else
        AST::Call.new(arg, operator)
      end
    else
      parse_atomic_with_method
    end
  end

  def parse_atomic_with_method
    parse_atomic
  end

  def parse_atomic : AST::Node
    case current_token.kind
    when .number?
      current_token_as(AST::NumberLiteral)
    when .char?
      current_token_as(AST::CharLiteral)
    when .string?
      current_token_as(AST::StringLiteral)
    when .symbol?
      current_token_as(AST::SymbolLiteral)
    when .global?
      add_error("$global_variables are not supported, use @@class_variables instead")
      current_token_as(AST::Error)
    when .kw_begin?
      parse_begin
    when .kw_nil?
      current_token_as(AST::NilLiteral)
    when .kw_true?
      current_token_as(AST::BoolLiteral)
    when .kw_false?
      current_token_as(AST::BoolLiteral)
    when .kw_with?
      parse_with
    when .kw_yield?
      parse_yield
    when .kw_abstract?
      abstract_token = current_token
      next_token

      case current_token.kind
      when .kw_class?, .kw_struct?
        parse_class_def(abstract_token)
      when .kw_def?
        parse_def(abstract_token)
      else
        add_error("abstract can only be used on class, struct, and def")
        AST::Error.new(abstract_token)
      end
    when .kw_class?, .kw_struct?
      parse_class_def
    when .kw_def?
      parse_def
    when .vt_skipped?
      current_token_as(AST::Error)
    when .eof?
      AST::Nop.new
    else
      add_error("unhandled parsing for token #{current_token.kind}")
      node = AST::Error.new(current_token)
      next_token
      node
    end
  end

  def parse_begin : AST::Node
    begin_token = consume(:KW_BEGIN)

    expressions = parse_expressions

    # TODO: parse exception handler

    end_token = consume(:KW_END)

    AST::Begin.new(begin_token, expressions.children, end_token)
  end

  def parse_with : AST::Node
    with_token = consume(:KW_WITH)
    scope = parse_op_assign

    parse_yield(with_token, scope)
  end

  def parse_yield(with_token : Token? = nil, scope : AST::Node? = nil) : AST::Node
    yield_token = consume(:KW_YIELD)
    lparen = consume?(:OP_LPAREN)

    args = parse_call_args

    if lparen
      rparen = consume(:OP_RPAREN)
    end

    AST::Yield.new(with_token, scope, yield_token, lparen, args, rparen)
  end

  def parse_call_args : Array(AST::Node)
    [] of AST::Node
  end

  def parse_class_def(abstract_token = nil) : AST::Node
    class_token = consume(:KW_CLASS)
    name = parse_path

    if arrow_token = consume?(:OP_LT)
      super_name = parse_path
    end

    body = parse_expressions
    end_token = consume(:KW_END)

    AST::ClassDef.new(
      abstract_token, class_token, name,
      arrow_token, super_name, body, end_token
    )
  end

  def parse_module_def : AST::Node
    module_token = consume(:KW_MODULE)
    name = parse_path

    # TODO: parse_type_vars
    body = parse_expressions
    end_token = consume(:KW_END)

    AST::ModuleDef.new(module_token, name, body, end_token)
  end

  # IDENT CONST ` << < <= == === != =~ !~ >> > >= + - * / // ! ~ % & | ^ ** [] []? []= <=> &+ &- &* &**
  DefOrMacroNameKinds = [
    :IDENT, :CONST, :OP_GRAVE,
    :OP_LT_LT, :OP_LT, :OP_LT_EQ, :OP_EQ_EQ, :OP_EQ_EQ_EQ, :OP_BANG_EQ, :OP_EQ_TILDE,
    :OP_BANG_TILDE, :OP_GT_GT, :OP_GT, :OP_GT_EQ, :OP_PLUS, :OP_MINUS, :OP_STAR, :OP_SLASH,
    :OP_SLASH_SLASH, :OP_BANG, :OP_TILDE, :OP_PERCENT, :OP_AMP, :OP_BAR, :OP_CARET, :OP_STAR_STAR,
    :OP_LSQUARE_RSQUARE, :OP_LSQUARE_RSQUARE_EQ, :OP_LSQUARE_RSQUARE_QUESTION, :OP_LT_EQ_GT,
    :OP_AMP_PLUS, :OP_AMP_MINUS, :OP_AMP_STAR, :OP_AMP_STAR_STAR,
  ] of TokenKind

  def parse_def(abstract_token : Token?  = nil) : AST::Node
    def_token = consume(:KW_DEF)

    if current_token.kind.const? || current_token.kind.op_colon_colon?
      receiver = parse_path
      receiver_dot = consume(:OP_PERIOD)
    end

    name = consume(DefOrMacroNameKinds)
    equals_token = consume?(:OP_EQ)

    return_colon = consume?(:OP_COLON)
    if return_colon
      return_type = parse_bare_proc_type
    end

    if abstract_token.nil?
      end_token = consume(:KW_END)
    end

    AST::Def.new(
      abstract_token, def_token, receiver, receiver_dot, name, equals_token,
      nil, return_colon, return_type, nil, end_token
    )
  end

  def parse_path : AST::Node
    start_colon = consume?(:OP_COLON_COLON)
    names = [consume(:CONST)]

    while current_token.kind.op_colon_colon?
      names << consume(:OP_COLON_COLON)
      names << consume(:CONST)
    end

    AST::Path.new(
      start_colon: start_colon,
      names: names,
    )
  end

  def parse_bare_proc_type : AST::Node
    # TODO: stuff
    parse_union_type
  end

  def parse_union_type : AST::Node
    last_type = parse_atomic_type_with_suffix
    unless current_token.kind.op_bar?
      return last_type
    end

    bar_token = consume(:OP_BAR)
    types = [{last_type, bar_token}] of {AST::Node, Token}

    loop do
      last_type = parse_atomic_type_with_suffix

      break unless current_token.kind.op_bar?

      bar_token = consume(:OP_BAR)
      types << {last_type, bar_token}
    end

    AST::Union.new(types, last_type)
  end

  def parse_atomic_type_with_suffix : AST::Node
    # TODO: stuff
    parse_path
  end

  # Helper methods

  def consume?(*kinds : TokenKind) : Token?
    if kinds.includes?(current_token.kind)
      token = current_token
      next_token

      token
    end
  end

  def consume(*kinds : TokenKind) : Token
    consume(kinds)
  end

  def consume(kinds : Tuple(TokenKind) | Array(TokenKind)) : Token
    if kinds.includes?(current_token.kind)
      token = current_token
      next_token

      token
    else
      add_error("expecting #{kinds.join(", ")}, but got #{current_token.kind}")
      Token.new(:VT_MISSING, 0, 0, false)
    end
  rescue ex
    add_error(ex.message || "exception")
    Token.new(:VT_MISSING, 0, 0, false)
  end

  def current_token : Token
    @tokens[@tokens_idx]
  end

  def next_token : Token
    @doc_idx += current_token.text_length
    @tokens_idx += 1
    @doc_idx += current_token.start

    current_token
  end

  def end_token? : Bool
    case current_token.kind
    when .op_rcurly?, .op_rsquare?, .op_percent_rcurly?, .eof?
      true
    when .kw_do?, .kw_end?, .kw_else?, .kw_elsif?, .kw_when?,
         .kw_in?, .kw_rescue?, .kw_ensure?, .kw_then?
      true
    else
      false
    end
  end

  def add_error(message) : Nil
    @errors << ParserError.new(
      message, @doc_idx
    )
  end

  macro current_token_as(name)
    node = {{ name }}.new(current_token)
    next_token
    node
  end
end
