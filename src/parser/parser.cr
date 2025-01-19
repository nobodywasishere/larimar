class Larimar::Parser
  Log = ::Larimar::Log.for(self)

  record(ParserError, message : String, pos : Int32)

  getter tokens : Array(Token)
  getter errors = Array(ParserError).new

  @tokens_idx = 0
  @doc_idx = 0

  @var_scopes = [Set(String).new]
  @parent_nodes = [:Nop] of AST::Node::ParentType

  def self.parse_full(document : Document) : Nil
    Lexer.lex_full(document)

    document.seek_to(0)

    parser = new(document)

    document.ast = parser.parse

    if parser.@doc_idx < document.@chars.size - 1
      parser.add_error("remaining source code not parsed")
    end

    document.parse_errors = parser.errors
  end

  def initialize(@document : Document)
    @tokens = @document.tokens
    @doc_idx = tokens[0]?.try(&.start) || 0
  end

  def parse : AST::Node
    ast = AST::Expressions.new([] of AST::Node)

    while true
      ast.children.concat(parse_expressions.children)

      if current_token.kind.eof?
        break
      else
        add_error("unexpected token")
        ast.children << AST::Error.new(current_token)
        next_token
      end
    end

    ast
  end

  def parse_expressions : AST::Node
    Log.debug { "#{@doc_idx}: parse_expressions" }

    node = AST::Expressions.new([] of AST::Node)

    if end_token?
      node.children << AST::Nop.new
      return node
    end

    loop do
      child = parse_multi_assign
      child.semicolon = consume?(:OP_SEMICOLON)
      node.children << child

      break if end_token?
    end

    node
  end

  def parse_multi_assign : AST::Node
    Log.debug { "#{@doc_idx}: parse_multi_assign" }

    # TODO: stuff
    parse_expression
  end

  def parse_expression : AST::Node
    Log.debug { "#{@doc_idx}: parse_expression" }

    # TODO: stuff
    parse_op_assign
  end

  def parse_op_assign : AST::Node
    Log.debug { "#{@doc_idx}: parse_op_assign" }

    # TODO: stuff
    atomic = parse_question_colon

    while true
      case current_token.kind
      when .op_eq?
        break unless can_be_assigned?(atomic)

        atomic_name = get_atomic_name(atomic)
        break unless atomic_name

        if atomic.is_a?(AST::Call) && atomic.name.kind.op_lsquare_rsquare?
          atomic.equals = consume(:OP_EQ)
          atomic.args << parse_op_assign_no_control
          next
        end

        if atomic.is_a?(AST::Self) || (atomic.is_a?(AST::Var) && (token = atomic.token) && token.kind.kw_self?)
          add_error("can't change the value of self")
        end

        atomic = AST::Var.new(atomic.name) if atomic.is_a?(AST::Call)

        case atomic
        when AST::Path
          needs_new_scope = true
        when AST::InstanceVar
          needs_new_scope = false # @def_nest == 0
        when AST::ClassVar
          needs_new_scope = false # @def_nest == 0
          # when Var
          # @assigns_special_var = true if atomic.special_var?
        else
          needs_new_scope = false
        end

        operator = consume(:OP_EQ)

        value = with_isolated_var_scope(needs_new_scope) do
          with_parent(:Assign) { parse_op_assign_no_control }
        end

        push_var(atomic_name)

        atomic = AST::Assign.new(atomic, operator, value)
      when .assignment_operator?
        break unless can_be_assigned?(atomic)

        atomic_name = get_atomic_name(atomic)
        break unless atomic_name

        if atomic.is_a?(AST::Path)
          add_error("can't reassign to constant")
        end

        if atomic.is_a?(AST::Self) || (atomic.is_a?(AST::Var) && (token = atomic.token) && token.kind.kw_self?)
          add_error("can't change the value of self")
        end

        # TODO: figure out why stdlib limited this to calls
        if !var_in_scope?(atomic_name) && !atomic.is_a?(AST::Path)
          add_error("assignment before definition of '#{atomic_name}'")
        end

        push_var(atomic_name)

        operator = next_token
        value = parse_op_assign_no_control

        atomic = AST::OpAssign.new(atomic, nil, operator, value)
      else
        break
      end
    end

    atomic
  end

  def can_be_assigned?(node : AST::Node) : Bool
    case node
    when AST::Var, AST::InstanceVar, AST::ClassVar, AST::Path, AST::Underscore, AST::Self
      true
    when AST::Call
      # TODO: check block
      node.lparen.nil? && ((node.obj.is_a?(AST::Nop) && node.args.empty?) || node.name.kind.op_lsquare_rsquare?)
    else
      false
    end
  end

  def get_atomic_name(node : AST::Node) : String?
    case node
    when AST::Path
      path_size = node.start_colon.try(&.text_length) || 0
      path_size += node.names.sum(&.text_length)
      @document.slice(
        @doc_idx - path_size - 1, path_size
      )
    when AST::Var, AST::InstanceVar, AST::ClassVar
      @document.slice(
        @doc_idx - node.token.text_length - 1, node.token.text_length
      )
    when AST::Call
      if node.args.empty? && !node.lparen && !node.block
        @document.slice(
          @doc_idx - node.name.text_length - 1, node.name.text_length
        )
      end
    end
  end

  def get_token_name(token : Token) : String?
    case token.kind
    when .string?
      @document.slice(
        @doc_idx - token.text_length, token.text_length - 2
      )
    when .ident?, .keyword?, .instance_var?, .class_var?
      @document.slice(
        @doc_idx - token.text_length - 1, token.text_length
      )
    end
  end

  def push_var(name : String)
    @var_scopes.last.add(name)
  end

  def parse_op_assign_no_control : AST::Node
    Log.debug { "#{@doc_idx}: parse_op_assign_no_control" }

    check_void_expression_keyword || parse_op_assign
  end

  def parse_question_colon : AST::Node
    Log.debug { "#{@doc_idx}: parse_question_colon" }

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
    Log.debug { "#{@doc_idx}: parse_range" }

    if current_token.kind.op_period_period? || current_token.kind.op_period_period_period?
      expression = AST::Nop.new
    else
      expression = parse_or
    end

    case current_token.kind
    when .op_period_period?, .op_period_period_period?
      expression = new_range(expression)
    end

    loop do
      if current_token.trivia_newline || current_token.kind.op_semicolon?
        break
      end

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
       current_token.trivia_newline || kind.op_semicolon?
      right = AST::Nop.new
    else
      right = parse_or
    end

    AST::RangeLiteral.new(expression, dots, right)
  end

  macro parse_operator(name, next_operator, node, *operators, right_associative = false)
    def parse_{{ name.id }} : AST::Node
      Log.debug { "#{@doc_idx}: parse_{{ name.id }}" }

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
    Log.debug { "#{@doc_idx}: parse_add_or_sub" }

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
    Log.debug { "#{@doc_idx}: parse_prefix" }

    case current_token.kind
    when .unary_operator?
      operator = current_token
      next_token

      arg = parse_prefix

      AST::Unary.new(operator, arg)
    else
      parse_atomic_with_method
    end
  end

  def parse_atomic_with_method
    Log.debug { "#{@doc_idx}: parse_atomic_with_method" }

    atomic = parse_atomic
    parse_atomic_method_suffix(atomic)
  end

  def parse_atomic_method_suffix(atomic : AST::Node, atomic_dot : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_atomic_method_suffix" }

    while true
      if current_token.trivia_newline
        case atomic
        when AST::ClassDef, AST::ModuleDef, AST::EnumDef, AST::Def # AST::FunDef
          break
        end

        if current_token.kind.op_period?
          break
        end
      end

      case current_token.kind
      when .op_period?
        check_void_value(atomic)
        dot_token = consume(:OP_PERIOD)

        if current_token.kind.instance_var?
          ivar = consume(:INSTANCE_VAR)

          atomic = AST::ReadInstanceVar.new(atomic, ivar)
          next
        end

        case current_token.kind
        when .kw_is_a_question?
          atomic = parse_is_a(atomic, dot_token)
        when .kw_as?
          atomic = parse_as(atomic)
        when .kw_as_question?
          atomic = parse_as?(atomic)
        when .kw_responds_to_question?
          atomic = parse_responds_to(atomic)
        when .kw_nil_question? # and not in macro expression
          atomic = parse_nil?(atomic)
        when .op_lsquare?
          return parse_atomic_method_suffix(atomic, dot_token)
        else
          # Don't include :OP_GRAVE
          method_token = consume(
            AtomicWithMethodKinds + PseudoMethodNames + KeywordKinds,
            msg: "expecting operator or method name"
          )

          case current_token.kind
          when .op_eq?
            equals_token = consume(:OP_EQ)
            args = [] of AST::Node

            if current_token.kind.op_lparen?
              lparen = consume(:OP_LPAREN)

              if current_token.kind.op_star?
                args << parse_single_arg
              else
                args << parse_op_assign_no_control
              end

              rparen = consume(:OP_RPAREN)
            else
              args << parse_single_arg
            end

            atomic = AST::Call.new(atomic, dot_token, equals_token, lparen, args, rparen, nil)
          when .assignment_operator?
            # TODO: how is this code called???
            value = parse_op_assign
            atomic = AST::OpAssign.new(atomic, dot_token, method_token, value)
          else
          end
        end

        break
      when .op_lsquare_rsquare?
        check_void_value(atomic)
        operator = consume(:OP_LSQUARE_RSQUARE)
        atomic = AST::Call.new(atomic, operator, dot: atomic_dot)
      when .op_lsquare?
        break
      else
        break
      end
    end

    atomic
  end

  def parse_single_arg : AST::Node
    Log.debug { "#{@doc_idx}: parse_single_arg" }

    if current_token.kind.op_star?
      star = consume(:OP_STAR)
      arg = parse_op_assign_no_control
      AST::Unary.new(star, arg)
    else
      parse_op_assign_no_control
    end
  end

  def parse_atomic : AST::Node
    Log.debug { "#{@doc_idx}: parse_atomic" }

    case current_token.kind
    when .op_lparen?
      parse_parenthesized_expression
    when .op_at_lsquare?
      parse_annotation
    when .op_lsquare_rsquare?
      parse_empty_array_literal
    when .op_lsquare?
      parse_array_literal
    when .op_colon_colon?
      # parse_generic_or_global_call
      parse_path
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
    when .op_dollar_tilde?, .op_dollar_question?
      current_token_as(AST::Var)
    when .magic_dir?, .magic_file?, .magic_line?
      current_token_as(AST::MagicConstant)
    when .magic_end_line?
      add_error("__END_LINE__ can only be used in default parameter value")
      current_token_as(AST::Error)
    when .kw_begin?
      parse_begin
    when .kw_nil?
      current_token_as(AST::NilLiteral)
    when .kw_true?
      current_token_as(AST::BoolLiteral)
    when .kw_false?
      current_token_as(AST::BoolLiteral)
    when .kw_self?
      current_token_as(AST::Self)
    when .underscore?
      current_token_as(AST::Underscore)
    when .instance_var?
      parse_instance_var
    when .class_var?
      parse_class_var
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
    when .kw_private?, .kw_protected?
      parse_visibility_modifier
    when .kw_class?, .kw_struct?
      parse_class_def
    when .kw_module?
      parse_module_def
    when .kw_enum?
      parse_enum_def
    when .kw_def?
      parse_def
    when .kw_macro?
      parse_macro
    when .kw_require?
      parse_require
    when .kw_annotation?
      parse_annotation_def
    when .kw_alias?
      parse_alias
    when .kw_case?
      parse_case
    when .kw_select?
      parse_select
    when .kw_if?
      parse_if
    when .kw_unless?
      parse_unless
    when .kw_include?
      parse_include
    when .kw_extend?
      parse_extend
    when .kw_is_a_question?
      obj = AST::Self.new(nil)
      parse_is_a(obj)
    when .kw_as?
      obj = AST::Self.new(nil)
      parse_as(obj)
    when .kw_as_question?
      obj = AST::Self.new(nil)
      parse_as?(obj)
    when .kw_responds_to_question?
      obj = AST::Self.new(nil)
      parse_responds_to(obj)
    when .kw_nil_question?
      # TODO: unless in macro exp
      obj = AST::Self.new(nil)
      parse_nil?(obj)
    when .ident?
      parse_var_or_call
    when .const?
      # parse_generic_or_custom_literal
      parse_path
    when .vt_skipped?, .vt_missing?
      current_token_as(AST::Error)
    else
      case current_parent
      when .array?
        case current_token.kind
        when .op_comma?, .op_rsquare?
          add_error("incomplete array element expression")
          return AST::Nop.new
        end
      when .assign?
        if (parent_parent = @parent_nodes[-2]?)
          case parent_parent
          when .class?, .module?, .def?, .enum?
            add_error("incomplete assign expression")
            return AST::Nop.new
          end
        end
      end

      case current_token.kind
      when .kw_end?
        token = Token.new(:VT_MISSING)
        node = AST::Error.new(token)
        add_error("expecting an expression")
        node
      when .eof?, .op_semicolon?
        AST::Nop.new
      else
        add_error("unhandled parsing for token #{current_token.kind}")
        current_token_as(AST::Error)
      end
    end
  end

  def parse_visibility_modifier : AST::Node
    Log.debug { "#{@doc_idx}: parse_visibility_modifier" }

    token = consume(:KW_PRIVATE, :KW_PROTECTED)
    value = parse_op_assign

    AST::VisibilityModifier.new(token, value)
  end

  def parse_var_or_call(
    obj : AST::Node? = nil, dot : Token? = nil,
    force_call : Bool = false, global : Bool = false,
  ) : AST::Node
    Log.debug { "#{@doc_idx}: parse_var_or_call" }

    case current_token.kind
    when .op_bang?
      # Should only trigger from `parse_when_expression`
      obj ||= AST::Self.new(nil)
      return parse_negation_suffix(obj: obj, dot: dot)
    when .kw_is_a_question?
      obj ||= AST::Self.new(nil)
      return parse_is_a(obj, dot: dot)
    when .kw_as?
      obj ||= AST::Self.new(nil)
      return parse_as(obj, dot: dot)
    when .kw_as_question?
      obj ||= AST::Self.new(nil)
      return parse_as?(obj, dot: dot)
    when .kw_responds_to_question?
      obj ||= AST::Self.new(nil)
      return parse_responds_to(obj, dot: dot)
    when .kw_nil_question?
      # TODO: unless in macro exp
      obj ||= AST::Self.new(nil)
      return parse_nil?(obj, dot: dot)
    end

    name_token = consume(:IDENT)
    # NOTE: no way to do this without pulling the actual string
    name_str = @document.slice(@doc_idx - name_token.text_length - 1, name_token.text_length)

    is_var = var?(name_str)
    if is_var && ([TokenKind::OP_PLUS, TokenKind::OP_MINUS].includes?(peek_next_token.kind))
      return current_token_as(AST::Var)
    end

    # TODO: some regex stuff

    # TODO: preserve stop on do
    call_args = parse_call_args

    # TODO: some block handling stuff
    args : Array(AST::Node)? = nil
    block = nil
    block_arg = nil
    named_args = nil

    obj ||= AST::Nop.new

    if block || block_arg || global
      AST::Call.new(
        obj: obj, dot: dot, name: name_token,
        lparen: nil, args: args || [] of AST::Node, rparen: nil,
        block: block
      )
    elsif args
      if !force_call && is_var
        AST::Var.new(name_token)
      else
        AST::Call.new(
          obj: obj, dot: dot, name: name_token,
          lparen: nil, args: args, rparen: nil,
          block: block
        )
      end
    elsif current_token.kind.op_colon? # and no type declaration
      var = parse_type_declaration(AST::Var.new(name_token))

      # TODO: don't push var if it's directly as an arg of a call
      push_var(name_str) # unless @call_args_start_locations.includes?(location)

      var
    elsif !force_call && is_var
      # TODO: some block stuff
      AST::Var.new(name_token)
    else
      # TODO: figure out how i want to handle this
      if !force_call && !named_args && !global && false # && @assigned_vars.includes?(name_str)
        add_error("can't use variable inside assignment to itself")
      end

      AST::Call.new(
        obj: obj, dot: dot, name: name_token,
        lparen: nil, args: [] of AST::Node, rparen: nil,
        block: block
      )
    end
  end

  def parse_negation_suffix(obj : AST::Node? = nil, dot : Token? = nil) : AST::Node
    bang = consume(:OP_BANG)

    lparen = consume?(:OP_LPAREN)
    if lparen
      rparen = consume(:OP_RPAREN)
    end

    AST::Call.new(
      obj: obj || AST::Nop.new,
      dot: dot,
      name: bang,
      lparen: lparen,
      args: [] of AST::Node,
      rparen: rparen,
      block: nil
    )
  end

  def var?(name : String) : Bool
    # return true if in macro expression
    name == "self" || var_in_scope?(name)
  end

  def var_in_scope?(name : String) : Bool
    Log.debug(&.emit("#{@doc_idx}: var_in_scope?", name: name, scopes: @var_scopes.to_json))
    @var_scopes.last.includes?(name)
  end

  def parse_is_a(atomic : AST::Node, dot : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_is_a" }

    token = consume(:KW_IS_A_QUESTION)
    lparen = consume?(:OP_LPAREN)
    if lparen
      type_name = parse_bare_proc_type
      rparen = consume(:OP_RPAREN)
    else
      type_name = parse_union_type
    end

    AST::IsA.new(atomic, dot, token, lparen, type_name, rparen)
  end

  def parse_as(atomic : AST::Node, dot : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_as" }

    token = consume(:KW_AS)
    lparen = consume?(:OP_LPAREN)
    if lparen
      type_name = parse_bare_proc_type
      rparen = consume(:OP_RPAREN)
    else
      type_name = parse_union_type
    end

    AST::Cast.new(atomic, dot, token, lparen, type_name, rparen)
  end

  def parse_as?(atomic : AST::Node, dot : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_as?" }

    token = consume(:KW_AS_QUESTION)
    lparen = consume?(:OP_LPAREN)
    if lparen
      type_name = parse_bare_proc_type
      rparen = consume(:OP_RPAREN)
    else
      type_name = parse_union_type
    end

    AST::NilableCast.new(atomic, dot, token, lparen, type_name, rparen)
  end

  def parse_responds_to(atomic : AST::Node, dot : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_responds_to" }

    token = consume(:KW_RESPONDS_TO_QUESTION)
    lparen = consume?(:OP_LPAREN)

    type_name = consume(:SYMBOL)

    if lparen
      rparen = consume(:OP_RPAREN)
    end

    AST::RespondsTo.new(atomic, dot, token, lparen, type_name, rparen)
  end

  def parse_nil?(atomic : AST::Node, dot : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_nil?" }

    token = consume(:KW_NIL_QUESTION)
    lparen = consume?(:OP_LPAREN)

    if lparen
      rparen = consume(:OP_RPAREN)
    end

    AST::IsNil.new(atomic, dot, token, lparen, rparen)
  end

  def parse_if : AST::Node
    Log.debug { "#{@doc_idx}: parse_if" }

    if_token = consume(:KW_IF)
    condition = parse_op_assign_no_control # allow_suffix: false
    expressions = parse_expressions

    elsif_nodes = Array(AST::Node).new
    else_node = nil

    while true
      case current_token.kind
      when .kw_elsif?
        elsif_token = consume(:KW_ELSIF)
        elsif_condition = parse_op_assign_no_control # allow_suffix: false
        elsif_expressions = parse_expressions

        elsif_nodes << AST::Elsif.new(elsif_token, elsif_condition, elsif_expressions)
      when .kw_else?
        else_token = consume(:KW_ELSE)
        else_expressions = parse_expressions

        else_node = AST::Else.new(else_token, else_expressions)
      else
        end_token = consume(:KW_END)
        break
      end
    end

    AST::If.new(if_token, condition, expressions, elsif_nodes, else_node, end_token)
  end

  def parse_unless : AST::Node
    Log.debug { "#{@doc_idx}: parse_unless" }

    unless_token = consume(:KW_UNLESS)
    condition = parse_op_assign_no_control # allow_suffix: false
    expressions = parse_expressions
    else_node = nil

    if current_token.kind.kw_else?
      else_token = consume(:KW_ELSE)
      else_expressions = parse_expressions

      else_node = AST::Else.new(else_token, else_expressions)
    end

    end_token = consume(:KW_END)

    AST::Unless.new(unless_token, condition, expressions, else_node, end_token)
  end

  def parse_parenthesized_expression : AST::Node
    Log.debug { "#{@doc_idx}: parse_parenthesized_expression" }

    lparen = consume(:OP_LPAREN)
    if current_token.kind.op_rparen?
      rparen = consume(:OP_RPAREN)
      return AST::Parenthesis.new(lparen, AST::Nop.new, rparen)
    end

    expressions = [] of AST::Node
    rparen = Token.new(:VT_MISSING)

    while true
      expression = parse_expression
      expressions << expression

      if current_token.kind.op_rparen?
        rparen = consume(:OP_RPAREN)
        break
      elsif current_token.kind.op_semicolon?
        expression.semicolon = consume(:OP_SEMICOLON)
      elsif current_token.trivia_newline
        # Keep going
      else
        # TODO: better error handling
        rparen = consume(:OP_RPAREN)
        break
      end
    end

    if current_token.kind.op_lparen?
      add_error("parenthesized expressions cannot immediately follow")
    end

    AST::Parenthesis.new(
      lparen, AST::Expressions.new(expressions), rparen
    )
  end

  def parse_require : AST::Node
    Log.debug { "#{@doc_idx}: parse_require" }

    require_token = consume(:KW_REQUIRE)
    require_str = consume(:STRING)

    AST::Require.new(require_token, require_str)
  end

  def parse_annotation_def : AST::Node
    Log.debug { "#{@doc_idx}: parse_annotation_def" }

    annotation_token = consume(:KW_ANNOTATION)
    name = parse_path
    annotation_end = consume(:KW_END)

    AST::AnnotationDef.new(annotation_token, name, annotation_end)
  end

  def parse_annotation : AST::Node
    Log.debug { "#{@doc_idx}: parse_annotation" }

    at_lsquare_token = consume(:OP_AT_LSQUARE)
    name = parse_path
    rsquare_token = consume(:OP_RSQUARE)

    # TODO: stuff

    AST::Annotation.new(at_lsquare_token, name, rsquare_token)
  end

  def parse_alias : AST::Node
    Log.debug { "#{@doc_idx}: parse_alias" }

    alias_token = consume(:KW_ALIAS)
    name = parse_path
    equals_token = consume(:OP_EQ)
    value = with_parent(:Assign) { parse_bare_proc_type }

    AST::Alias.new(alias_token, name, equals_token, value)
  end

  def parse_empty_array_literal : AST::Node
    Log.debug { "#{@doc_idx}: parse_empty_array_literal" }

    lsquare_rsquare_token = consume(:OP_LSQUARE_RSQUARE)
    of_token = consume(:KW_OF, msg: "for empty arrays use '[] of ElementType'")
    if of_token.kind.kw_of?
      type_name = parse_bare_proc_type
    end

    AST::ArrayLiteral.new(
      left_bracket: lsquare_rsquare_token,
      elements: nil,
      last_element: nil,
      right_bracket: nil,
      of_token: of_token,
      type_name: type_name
    )
  end

  def parse_array_literal : AST::Node
    Log.debug { "#{@doc_idx}: parse_array_literal" }

    lsquare_token = consume(:OP_LSQUARE)
    elements = Array(Tuple(AST::Node, Token)).new

    while true
      # TODO: op_star/splat handling
      last_element = with_parent(:array) { parse_op_assign_no_control }

      if current_token.kind.op_comma?
        comma_token = consume(:OP_COMMA)

        if current_token.kind.op_rsquare?
          rsquare_token = consume(:OP_RSQUARE)
          break
        else
          elements << {last_element, comma_token}
        end
      else
        rsquare_token = consume(:OP_RSQUARE)
        break
      end
    end

    of_token = consume?(:KW_OF)
    if of_token
      type_name = parse_bare_proc_type
    end

    AST::ArrayLiteral.new(
      left_bracket: lsquare_token,
      elements: elements,
      last_element: last_element,
      right_bracket: rsquare_token,
      of_token: of_token,
      type_name: type_name
    )
  end

  def parse_instance_var : AST::Node
    Log.debug { "#{@doc_idx}: parse_instance_var" }

    token = consume(:INSTANCE_VAR)
    node = AST::InstanceVar.new(token)

    if current_token.kind.op_colon?
      node = parse_type_declaration(node)
    end

    node
  end

  def parse_class_var : AST::Node
    Log.debug { "#{@doc_idx}: parse_class_var" }

    token = consume(:CLASS_VAR)
    node = AST::ClassVar.new(token)

    if current_token.kind.op_colon?
      node = parse_type_declaration(node)
    end

    node
  end

  def parse_type_declaration(node : AST::Node) : AST::Node
    Log.debug { "#{@doc_idx}: parse_type_declaration" }

    colon_token = consume(:OP_COLON)
    type_name = parse_bare_proc_type

    equals_token = consume?(:OP_EQ)
    if equals_token
      value = with_parent(:Assign) { parse_op_assign_no_control }
    end

    AST::TypeDeclaration.new(node, colon_token, type_name, equals_token, value)
  end

  def parse_case : AST::Node
    Log.debug { "#{@doc_idx}: parse_case" }

    case_token = consume(:KW_CASE)

    case current_token.kind
    when .kw_when?, .kw_else?, .kw_end?
    else
      condition = parse_op_assign_no_control
    end

    when_expressions = Array(AST::Node).new
    end_token = Token.new(:VT_MISSING)
    exhaustive = nil

    while true
      case current_token.kind
      when .kw_when?, .kw_in?
        when_token = consume(:KW_WHEN, :KW_IN)

        if exhaustive.nil?
          exhaustive = current_token.kind.kw_in?

          if exhaustive && condition.nil?
            add_error("exhaustive case (case ... in) requires a case expression (case exp; in ..)")
          end
        elsif exhaustive && current_token.kind.kw_when?
          add_error("expected 'in', not 'when'")
        elsif !exhaustive && current_token.kind.kw_in?
          add_error("expected 'when', not 'in'")
        end

        # TODO: stuff
        # if condition.is_a?(AST::TupleLiteral)
        when_conditions = Array(Tuple(AST::Node, Token)).new
        then_token = nil
        last_condition = nil

        while true
          # Added to this parser over the stdlib one as this happens
          # often when writing case statements
          case current_token.kind
          when .kw_when?, .kw_in?, .kw_end?, .kw_then?, .eof?, .kw_else?
            if exhaustive
              add_error("empty 'in' condition")
            else
              add_error("empty 'when' condition")
            end

            then_token = consume?(:KW_THEN)
            last_condition = AST::Nop.new
            break
          else
            last_condition = parse_when_expression(!!condition, single: true, exhaustive: exhaustive)
          end

          if (then_token = consume?(:KW_THEN)) || current_token.trivia_newline ||
             current_token.kind.op_semicolon? || current_token.kind.eof?
            break
          end

          comma = consume(:OP_COMMA)
          when_conditions << {last_condition, comma}
        end

        when_body = parse_expressions
        when_expressions << AST::When.new(when_token, when_conditions, last_condition, then_token, when_body)
      when .kw_else?
        else_token = consume(:KW_ELSE)
        else_expressions = parse_expressions

        else_node = AST::Else.new(else_token, else_expressions)
      when .kw_end?
        end_token = consume(:KW_END)
        break
      else
        add_error("expecting when, else, or end")
        when_expressions << current_token_as(AST::Error)
        break
      end
    end

    AST::Case.new(case_token, condition, when_expressions, else_node, end_token)
  end

  def parse_select : AST::Node
    Log.debug { "#{@doc_idx}: parse_select" }

    select_token = consume(:KW_SELECT)

    when_expressions = Array(AST::Node).new
    else_node = nil
    end_token = Token.new(:VT_MISSING)

    while true
      case current_token.kind
      when .kw_when?, .kw_in?
        if current_token.kind.kw_in?
          add_error("select only supports 'in' statements")
        end

        when_token = consume(:KW_WHEN, :KW_IN)
        when_conditions = Array(Tuple(AST::Node, Token)).new
        then_token = nil
        last_condition = nil

        while true
          # Added to this parser over the stdlib one as this happens
          # often when writing case statements
          case current_token.kind
          when .kw_when?, .kw_in?, .kw_end?, .kw_then?, .eof?
            add_error("empty 'when' condition")

            then_token = consume?(:KW_THEN)
            last_condition = AST::Nop.new
            break
          end

          last_condition = parse_op_assign_no_control
          unless valid_select_when?(last_condition)
            add_error("invalid select when expression: must be an assignment or call")
          end

          if (then_token = consume?(:KW_THEN)) || current_token.trivia_newline ||
             current_token.kind.op_semicolon? || current_token.kind.eof?
            break
          end

          comma = consume(:OP_COMMA)
          when_conditions << {last_condition, comma}
        end

        when_body = parse_expressions
        when_expressions << AST::When.new(when_token, when_conditions, last_condition, then_token, when_body)
      when .kw_else?
        if when_expressions.size == 0
          add_error("expecting when expression")
        end

        else_token = consume(:KW_ELSE)
        else_expressions = parse_expressions

        else_node = AST::Else.new(else_token, else_expressions)
      when .kw_end?
        if when_expressions.size == 0 && else_node.nil?
          add_error("expecting when expression")
        end

        end_token = consume(:KW_END)
        break
      else
        add_error("expecting when, else, or end")
        when_expressions << current_token_as(AST::Error)
        break
      end
    end

    AST::Select.new(select_token, when_expressions, else_node, end_token)
  end

  def parse_when_expression(condition : Bool, single : Bool, exhaustive : Bool) : AST::Node
    Log.debug { "#{@doc_idx}: parse_when_expression" }

    if current_token.kind.op_period?
      if !condition
        add_error("implicit when expressions require a condition")
      end

      dot_token = consume(:OP_PERIOD)
      call = parse_var_or_call(obj: AST::ImplicitObj.new, dot: dot_token, force_call: true)

      case call
      when AST::Call, AST::RespondsTo, AST::IsA, AST::Cast, AST::NilableCast
      when AST::Var
        # TODO: patch until `parse_var_or_call` is looked at
      when AST::Not
        # call.expression = AST::ImplicitObj.new
      else
        add_error("expected Call, RespondsTo, IsA, Cast, or Nilable")
      end

      call
    elsif single && current_token.kind.underscore?
      if exhaustive
        add_error("'when _' is not supported")
      else
        add_error("'when _' is not supported, use 'else' block instead")
      end
      current_token_as(AST::Error)
    else
      parse_op_assign_no_control
    end
  end

  def valid_select_when?(node : AST::Node)
    # TODO: stuff
    # case node
    # when AST::Assign
    #   node.value.is_a?(AST::Call)
    # when AST::Call
    #   true
    # else
    #   false
    # end
    true
  end

  def parse_begin : AST::Node
    Log.debug { "#{@doc_idx}: parse_begin" }

    begin_token = consume(:KW_BEGIN)

    expressions = parse_expressions

    # TODO: parse exception handler

    end_token = consume(:KW_END)

    AST::Begin.new(begin_token, expressions.children, end_token)
  end

  def parse_with : AST::Node
    Log.debug { "#{@doc_idx}: parse_with" }

    with_token = consume(:KW_WITH)
    scope = parse_op_assign

    parse_yield(with_token, scope)
  end

  def parse_yield(with_token : Token? = nil, scope : AST::Node? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_yield" }

    yield_token = consume(:KW_YIELD)
    lparen = consume?(:OP_LPAREN)

    args = parse_call_args

    if lparen
      rparen = consume(:OP_RPAREN)
    end

    AST::Yield.new(with_token, scope, yield_token, lparen, args, rparen)
  end

  def parse_call_args : Array(AST::Node)
    Log.debug { "#{@doc_idx}: parse_call_args" }

    [] of AST::Node
  end

  def parse_class_def(abstract_token = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_class_def" }

    class_token = consume(:KW_CLASS)
    name = parse_path

    if arrow_token = consume?(:OP_LT)
      super_name = parse_path
    end

    body = with_parent(:Class) { parse_expressions }
    end_token = consume(:KW_END)

    AST::ClassDef.new(
      abstract_token, class_token, name,
      arrow_token, super_name, body, end_token
    )
  end

  def parse_module_def : AST::Node
    Log.debug { "#{@doc_idx}: parse_module_def" }

    module_token = consume(:KW_MODULE)
    name = parse_path

    # TODO: parse_type_vars
    body = with_parent(:Module) { parse_expressions }
    end_token = consume(:KW_END)

    AST::ModuleDef.new(module_token, name, body, end_token)
  end

  def parse_include : AST::Node
    Log.debug { "#{@doc_idx}: parse_include" }

    token = consume(:KW_INCLUDE)

    if current_token.kind.kw_self?
      self_token = consume(:KW_SELF)
      name = AST::Self.new(self_token)
    else
      # parse_generic
      name = parse_path
    end

    AST::Include.new(token, name)
  end

  def parse_extend : AST::Node
    Log.debug { "#{@doc_idx}: parse_extend" }

    token = consume(:KW_EXTEND)

    if current_token.kind.kw_self?
      self_token = consume(:KW_SELF)
      name = AST::Self.new(self_token)
    else
      name = parse_path # parse_generic
    end

    AST::Extend.new(token, name)
  end

  def parse_enum_def : AST::Node
    Log.debug { "#{@doc_idx}: parse_enum_def" }

    enum_token = consume(:KW_ENUM)
    name = parse_path

    colon = consume?(:OP_COLON)
    if colon
      base_type = parse_bare_proc_type
    end

    members = parse_enum_body_expressions

    end_token = consume(:KW_END)

    AST::EnumDef.new(enum_token, name, colon, base_type, members, end_token)
  end

  def parse_enum_body_expressions : Array(AST::Node)
    Log.debug { "#{@doc_idx}: parse_enum_body_expressions" }

    members = [] of AST::Node

    while true
      case current_token.kind
      when .const?
        const_name = consume(:CONST)
        equals_token = consume?(:OP_EQ)
        if equals_token
          const_value = with_parent(:Assign) { parse_logical_or }
        end

        unless current_token.trivia_newline || current_token.kind.op_semicolon? || current_token.kind.eof?
          add_error("expecting ';', 'end', or newline after enum member")
        end

        arg = AST::Arg.new(nil, const_name, equals_token, const_value)
        arg.semicolon = consume?(:OP_SEMICOLON)

        members << arg
      when .kw_private?, .kw_protected?
        visibility_token = consume(:KW_PRIVATE, :KW_PROTECTED)

        case current_token.kind
        when .kw_def?
          def_node = parse_def

          if visibility_token
            members << AST::VisibilityModifier.new(visibility_token, def_node)
          else
            members << def_node
          end
        when .kw_macro?
          macro_node = parse_macro

          if visibility_token
            members << AST::VisibilityModifier.new(visibility_token, macro_node)
          else
            members << macro_node
          end
        else
          add_error("expecting method or macro def after visibility modifier")
          members << current_token_as(AST::Error)
        end
      when .kw_def?
        members << parse_def
      when .kw_macro?
        members << parse_macro
      when .class_var?
        class_var = current_token_as(AST::ClassVar)
        equals_token = consume?(:OP_EQ)

        if equals_token
          value = with_parent(:Assign) { parse_op_assign }
          members << AST::Assign.new(class_var, equals_token, value)
        else
          add_error("@@class_variables must be assigned inside enums")
          members << AST::Error.new(class_var.token)
        end
        # when .op_lcurly_lcurly?
        # when .op_lcurly_percent?
      when .op_at_lsquare?
        members << parse_annotation
      when .op_semicolon?
        member = AST::Nop.new
        member.semicolon = consume(:OP_SEMICOLON)
        members << member
      when .kw_end?, .eof?
        break
      else
        add_error("expecting enum member or method/macro definition")
        members << current_token_as(AST::Error)
      end
    end

    members
  end

  # IDENT CONST ` << < <= == === != =~ !~ >> > >= + - * / // ! ~ % & | ^ ** [] []? []= <=> &+ &- &* &**
  DefOrMacroNameKinds = begin
    AtomicWithMethodKinds + KeywordKinds + PseudoMethodNames + [:OP_GRAVE] of TokenKind
  end

  AtomicWithMethodKinds = [
    :IDENT, :CONST,
    :OP_AMP_MINUS, :OP_AMP_PLUS, :OP_AMP_STAR_STAR, :OP_AMP_STAR, :OP_AMP,
    :OP_BANG_EQ, :OP_BANG_TILDE, :OP_BANG, :OP_BAR, :OP_CARET,
    :OP_EQ_EQ_EQ, :OP_EQ_EQ, :OP_EQ_TILDE,
    :OP_GT_EQ, :OP_GT_GT, :OP_GT,
    :OP_LSQUARE_RSQUARE_EQ, :OP_LSQUARE_RSQUARE_QUESTION, :OP_LSQUARE_RSQUARE, :OP_LSQUARE,
    :OP_LT_EQ_GT, :OP_LT_EQ, :OP_LT_LT, :OP_LT,
    :OP_MINUS, :OP_PERCENT, :OP_PLUS,
    :OP_SLASH_SLASH, :OP_SLASH, :OP_STAR_STAR, :OP_STAR, :OP_TILDE,
  ] of TokenKind

  KeywordKinds = [
    :KW_ABSTRACT, :KW_ALIAS, :KW_ALIGNOF, :KW_ANNOTATION,
    :KW_ASM, :KW_BEGIN, :KW_BREAK, :KW_CASE, :KW_CLASS,
    :KW_DEF, :KW_DO, :KW_ELSE, :KW_ELSIF, :KW_END, :KW_ENSURE,
    :KW_ENUM, :KW_EXTEND, :KW_FALSE, :KW_FOR, :KW_FORALL,
    :KW_FUN, :KW_IF, :KW_IN, :KW_INCLUDE, :KW_INSTANCE_ALIGNOF,
    :KW_INSTANCE_SIZEOF, :KW_LIB, :KW_MACRO, :KW_MODULE,
    :KW_NEXT, :KW_NIL, :KW_OF, :KW_OFFSETOF, :KW_OUT,
    :KW_POINTEROF, :KW_PRIVATE, :KW_PROTECTED, :KW_REQUIRE,
    :KW_RESCUE, :KW_RETURN, :KW_SELECT, :KW_SELF, :KW_SIZEOF,
    :KW_STRUCT, :KW_SUPER, :KW_THEN, :KW_TRUE, :KW_TYPE,
    :KW_TYPEOF, :KW_UNINITIALIZED, :KW_UNION, :KW_UNLESS,
    :KW_UNTIL, :KW_VERBATIM, :KW_WHEN, :KW_WHILE, :KW_WITH,
    :KW_YIELD,
  ] of TokenKind

  PseudoMethodNames = [
    :KW_AS_QUESTION, :KW_AS, :KW_IS_A_QUESTION,
    :KW_NIL_QUESTION, :KW_RESPONDS_TO_QUESTION,
  ] of TokenKind

  def parse_def(abstract_token : Token? = nil) : AST::Node
    Log.debug { "#{@doc_idx}: parse_def" }

    def_token = consume(:KW_DEF)

    with_isolated_var_scope do
      if current_token.kind.const? || current_token.kind.op_colon_colon?
        receiver = parse_path
        receiver_dot = consume(:OP_PERIOD)
      end

      if PseudoMethodNames.includes?(current_token.kind)
        add_error("this is a pseudo-method and can't be redefined")
        name = consume(PseudoMethodNames).skipped
      elsif current_token.kind.op_bang?
        add_error("'!' is a pseudo-method and can't be redefined")
        name = consume(:OP_BANG).skipped
      else
        name = consume(
          DefOrMacroNameKinds,
          msg: "expecting operator or method name"
        )
      end

      equals_token = consume?(:OP_EQ)

      params = [] of {AST::Node, Token}
      last_param = nil

      case current_token.kind
      when .op_lparen?
        lparen = consume(:OP_LPAREN)

        while !current_token.kind.op_rparen?
          last_param = parse_param

          if current_token.kind.op_rparen? || current_token.kind.eof?
            break
          elsif current_token.kind.op_comma?
            comma = consume(:OP_COMMA)
            params << {last_param, comma}
            last_param = nil

            if current_token.kind.op_rparen? || current_token.kind.eof?
              add_error("expected param")
              last_param = AST::Error.new(Token.new(:VT_MISSING))
            end
          else
            add_error("unexpected token")
            params << {current_token_as(AST::Error), Token.new(:VT_MISSING)}
          end
        end

        rparen = consume(:OP_RPAREN)
      when .op_semicolon?, .op_colon?
        # Skip
      when .op_amp?
        # TODO: add error for mandatory parethesis
      when .symbol?
        # TODO: add error "a space is mandatory between ':' and return type"
      when .eof?
      else
        if current_token.trivia_newline || abstract_token
          # OK
        else
          add_error("unexpected token")
          params << {AST::Error.new(current_token), Token.new(:VT_MISSING)}
          next_token
        end
      end

      return_colon = consume?(:OP_COLON)
      if return_colon
        return_type = parse_bare_proc_type
      end

      forall_token = consume?(:KW_FORALL)
      if forall_token
        free_vars = parse_def_free_vars
      end

      if abstract_token.nil?
        body = with_parent(:Def) { parse_expressions }
        end_token = consume(:KW_END)
      end

      return AST::Def.new(
        abstract_token, def_token, receiver, receiver_dot, name, equals_token,
        lparen, params, last_param, rparen, return_colon, return_type,
        forall_token, free_vars, body, end_token
      )
    end
  end

  def parse_def_free_vars : Array(Token)
    Log.debug { "#{@doc_idx}: parse_def_free_vars" }

    free_vars = [] of Token
    free_var_names = [] of String

    while true
      free_var = consume(:CONST)
      free_var_name = @document.slice(
        @doc_idx - free_var.text_length - current_token.start,
        free_var.text_length
      )

      if free_var_names.includes?(free_var_name)
        add_error(
          "duplicated free variable name: #{free_var_name}",
          location: @doc_idx - free_var.text_length - current_token.start
        )
      end

      free_var_names << (free_var_name || "")
      free_vars << free_var

      if current_token.kind.op_comma?
        free_vars << consume(:OP_COMMA)
      else
        break
      end
    end

    free_vars
  end

  def parse_param : AST::Node
    Log.debug { "#{@doc_idx}: parse_param" }

    annotations = nil
    while current_token.kind.op_at_lsquare?
      (annotations ||= Array(AST::Node).new) << parse_annotation
    end

    allow_external_name = true
    allow_restrictions = true
    splat_token = nil

    case current_token.kind
    when .op_star?
      allow_external_name = false
      splat_token = consume(:OP_STAR)
    when .op_star_star?
      allow_external_name = false
      splat_token = consume(:OP_STAR_STAR)
    end

    if splat_token.try(&.kind.op_star?) && (current_token.kind.op_comma? || current_token.kind.op_rparen?)
      param_name = nil
      allow_restrictions = false
    else
      external_name, external_str, param_name, param_str = parse_param_name(allow_external_name)
    end

    restriction = nil
    if current_token.kind.op_colon?
      if !allow_restrictions
        add_error("restrictions not allowed for this parameter")
      end

      colon_token = consume(:OP_COLON)

      # TODO: handle splat restrictions
      restriction = parse_bare_proc_type
    end

    default_value = nil
    if current_token.kind.op_eq?
      equals_token = consume(:OP_EQ)

      if splat_token.try(&.kind.op_star?)
        add_error("splat parameter can't have default value")
      elsif splat_token.try(&.kind.op_star_star?)
        add_error("double splat parameter can't have default value")
      end

      if current_token.kind.magic?
        default_value = current_token_as(AST::MagicConstant)
      else
        default_value = parse_op_assign
      end
    end

    push_var(param_str) if param_str

    AST::Arg.new(
      annotations: annotations, splat: splat_token,
      ext_name: external_name, name: param_name,
      colon: colon_token, restriction: restriction,
      equals_token: equals_token, value: default_value
    )
  end

  def parse_param_name(allow_external_name : Bool) : {Token?, String?, Token?, String?}
    Log.debug { "#{@doc_idx}: parse_param_name" }

    external_name = nil
    external_str = nil
    param_name = nil
    param_str = nil

    if allow_external_name
      external_name = consume?(TokenKind::IDENT, TokenKind::STRING)
      external_str = get_token_name(external_name) if external_name
    end

    case current_token.kind
    when .ident?
      # if current_token.kind.keyword?
      #   add_error("cannot use keyword as a parameter name")
      # end

      loc = @doc_idx
      param_name = consume(:IDENT)
      param_str = get_token_name(param_name)

      if param_str == external_str
        add_error(
          "when specified, external name must be different than internal name",
          location: loc
        )
      end
    when .instance_var?
      loc = @doc_idx
      param_name = next_token
      param_str = get_token_name(param_name).try &.[1..-1]

      if param_str == external_str
        add_error(
          "when specified, external name must be different than internal name",
          location: loc
        )
      end
    when .class_var?
      loc = @doc_idx
      param_name = next_token
      param_str = get_token_name(param_name).try &.[2..-1]

      if param_str == external_str
        add_error(
          "when specified, external name must be different than internal name",
          location: loc
        )
      end
    else
      if external_name
        if external_name.kind.string?
          add_error("expected paramater internal name")
          param_name = Token.new(:VT_MISSING)
        else
          param_name = external_name
          param_str = external_str
          external_name = nil
          external_str = nil
        end
      end
    end

    {external_name, external_str, param_name, param_str}
  end

  def parse_macro : AST::Node
    Log.debug { "#{@doc_idx}: parse_macro" }

    macro_token = consume(:KW_MACRO)

    with_isolated_var_scope do
      if PseudoMethodNames.includes?(current_token.kind)
        add_error("this is a pseudo-method and can't be redefined")
        name = consume(PseudoMethodNames).skipped
      elsif current_token.kind.op_bang?
        add_error("'!' is a pseudo-method and can't be redefined")
        name = consume(:OP_BANG).skipped
      else
        name = consume(
          DefOrMacroNameKinds,
          msg: "expecting operator or method name"
        )
      end

      equals_token = consume?(:OP_EQ)

      # TODO: parse_macro_body

      end_token = consume(:KW_END)

      AST::Macro.new(
        macro_token, name, equals_token, nil, nil, end_token
      )
    end
  end

  def parse_path : AST::Node
    Log.debug { "#{@doc_idx}: parse_path" }

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
    Log.debug { "#{@doc_idx}: parse_bare_proc_type" }

    # TODO: stuff
    parse_union_type
  end

  def parse_union_type : AST::Node
    Log.debug { "#{@doc_idx}: parse_union_type" }

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
    Log.debug { "#{@doc_idx}: parse_atomic_type_with_suffix" }
    # TODO: stuff
    parse_path
  end

  def check_void_expression_keyword : AST::Node?
    case current_token.kind
    when .kw_break?, .kw_next?, .kw_return?
      add_error("void value expression")
      current_token_as(AST::Error)
    end
  end

  def check_void_value(node : AST::Node) : Nil
    case node
    # TODO: stuff
    # when AST::ControlExpression
    end
  end

  def with_isolated_var_scope(create_scope = true, &)
    return yield unless create_scope

    begin
      @var_scopes.push(Set(String).new)
      yield
    ensure
      @var_scopes.pop
    end
  end

  def with_lexical_var_scope(&)
    current_scope = @var_scopes.last.dup
    @var_scopes.push(current_scope)
    yield
  ensure
    @var_scopes.pop
  end

  def with_parent(node : AST::Node::ParentType, &) : AST::Node
    @parent_nodes.push(node)

    yield
  ensure
    @parent_nodes.pop
  end

  # Helper methods

  def consume?(*kinds : TokenKind, msg : String? = nil) : Token?
    if kinds.includes?(current_token.kind)
      token = current_token
      next_token

      token
    end
  end

  def consume(*kinds : TokenKind, msg : String? = nil) : Token
    consume(kinds.to_a, msg: msg)
  end

  def consume(kinds : Array(TokenKind), msg : String? = nil) : Token
    if kinds.includes?(current_token.kind)
      token = current_token
      next_token

      token
    else
      msg ||= "expecting #{kinds.join(", ")}, but got #{current_token.kind}"
      add_error(msg)
      Token.new(:VT_MISSING)
    end
  end

  def current_token : Token
    @tokens[@tokens_idx]
  end

  def current_parent : AST::Node::ParentType
    @parent_nodes.last
  end

  def next_token : Token
    @doc_idx += current_token.text_length
    @tokens_idx += 1
    @doc_idx += current_token.start

    current_token
  end

  def peek_next_token : Token
    @tokens[@tokens_idx + 1]? || Token.new(:VT_MISSING)
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

  def add_error(message, location = @doc_idx) : Nil
    @errors << ParserError.new(
      message, location
    )
  end

  macro current_token_as(name)
    node = {{ name }}.new(current_token)
    next_token unless current_token.kind.eof?
    node
  end
end
