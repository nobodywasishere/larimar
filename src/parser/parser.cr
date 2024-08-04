class Larimar::Parser
  Log = ::Larimar::Log.for(self)

  record(ParserError, message : String, pos : Int32)

  getter tokens : Array(Token)
  getter errors = Array(ParserError).new

  @tokens_idx = 0
  @doc_idx = 0

  def initialize(@tokens)
    @doc_idx = tokens[0]?.try(&.start) || 0
  end

  def parse : AST::Node
    parse_expressions
  end

  def parse_expressions : AST::Node
    if current_token.kind.eof?
      return AST::Nop.new(nil)
    end

    expression = parse_multi_assign

    if current_token.kind.eof?
      return expression
    end

    expressions = [expression] of AST::Node

    loop do
      expressions << parse_multi_assign
      break if current_token.kind.eof?
    end

    AST::Expressions.new(nil, expressions)
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

    # TODO: stuff
    # while current_token.type.op_question?
    # end

    cond
  end

  def parse_range : AST::Node
    if current_token.kind.op_period_period? || current_token.kind.op_period_period_period?
      expression = AST::Nop.new(nil)
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
    if kind.eof? || kind.op_rparen? || kind.op_comma? || kind.op_eq_gt? ||
        kind.op_semicolon? || current_token.trivia_newline
      right = AST::Nop.new(nil)
    else
      right = parse_or
    end

    AST::RangeLiteral.new(nil, expression, dots, right)
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

  parse_operator or, and, "AST::Or.new nil, left, operator, right", :op_bar_bar?
  parse_operator and, equality, "AST::And.new nil, left, operator, right", :op_amp_amp?
    parse_operator equality, cmp, "AST::Call.new nil, left, operator, right", :op_lt?, :op_lt_eq?, :op_gt?, :op_gt_eq?, :op_lt_eq_gt?
    parse_operator cmp, logical_or, "AST::Call.new nil, left, operator, right", :op_eq_eq?, :op_bang_eq?, :op_eq_tilde?, :op_bang_tilde?, :op_eq_eq_eq?
    parse_operator logical_or, logical_and, "AST::Call.new nil, left, operator, right", :op_bar?, :op_caret?
    parse_operator logical_and, shift, "AST::Call.new nil, left, operator, right", :op_amp?
    parse_operator shift, add_or_sub, "AST::Call.new nil, left, operator, right", :op_lt_lt?, :op_gt_gt?

  def parse_add_or_sub : AST::Node
    left = parse_mul_or_div

    while true
      case current_token.kind
      when .op_plus?, .op_minus?, .op_amp_plus?, .op_amp_minus?
        operator = current_token
        next_token

        right = parse_mul_or_div

        left = AST::Call.new nil, left, operator, right
      # when .number?
      # TODO: stuff
      else
        return left
      end
    end
  end

  parse_operator mul_or_div, pow, "AST::Call.new nil, left, operator, right", :op_star?, :op_slash?, :op_slash_slash?, :op_percent?, :op_amp_star?
  parse_operator pow, prefix, "AST::Call.new nil, left, operator, right", :op_star_star?, :op_amp_star_star?, right_associative: true

  def parse_prefix : AST::Node
    case current_token.kind
    when .unary_operator?
      operator = current_token
      next_token

      arg = parse_prefix

      if operator.kind.op_bang?
        AST::Not.new(nil, arg, operator)
      else
        AST::Call.new(nil, arg, operator)
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
    when .kw_nil?
      current_token_as(AST::NilLiteral)
    when .kw_true?
      current_token_as(AST::BoolLiteral)
    else
      add_error("unhandled parsing for token #{current_token.kind}")
      token = AST::Nop.new(nil)
      next_token
      token
    end
  end

  def parse_path : AST::Node
    start_colon = consume?(:OP_COLON_COLON)
    names = [consume(:CONST)]

    while current_token.kind.op_colon_colon?
      names << consume(:OP_COLON_COLON)
      names << consume(:CONST)
    end

    AST::Path.new(
      parent: nil,
      start_colon: start_colon,
      names: names,
    )
  end

  def consume?(kind : TokenKind) : Token?
    if current_token.kind == kind
      token = current_token
      next_token

      token
    end
  end

  def consume(kind : TokenKind) : Token
    if current_token.kind == kind
      token = current_token
      next_token

      token
    else
      add_error("expecting #{kind}, but got #{current_token.kind}")
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

  def add_error(message) : Nil
    @errors << ParserError.new(
      message, @doc_idx
    )
  end

  macro current_token_as(name)
    node = {{ name }}.new(nil, current_token)
    next_token
    node
  end
end
