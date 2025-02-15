require "tree_sitter"
require "./larimar/compiler"

# This converts a Crystal tree-sitter AST into a Crystal stdlib AST
class TreeSitterConverter
  getter! source : String

  @inside_def : Bool = false

  def initialize
    @parser = TreeSitter::Parser.new("crystal")
  end

  def parse(@path : String?, @source : String) : Crystal::Expressions
    tree = @parser.parse(nil, source)
    convert_program(tree.root_node)
  end

  private def convert_program(node : TreeSitter::Node) : Crystal::Expressions
    expressions = [] of Crystal::ASTNode

    node.child_count.times do |i|
      child = node.child(i.to_i32)

      if (ast_node = convert_node(child))
        expressions << ast_node
      end
    end

    Crystal::Expressions.new(expressions)
  end

  private def convert_node(node : TreeSitter::Node) : Crystal::ASTNode?
    # puts "node type: #{node.type}"
    case node.type
    when "require"
      convert_require(node)
    when "true", "false"
      convert_bool(node)
    when "nil"
      Crystal::NilLiteral.new
    when "type_declaration"
      convert_type_declaration(node)
    when "class_def"
      convert_class_def(node)
    when "string"
      Crystal::StringLiteral.new(text(node)[1..-2])
    when "symbol"
      Crystal::SymbolLiteral.new(text(node)[1..])
    when "call"
      convert_call(node)
    when "implicit_object_call"
      convert_implicit_object_call(node)
    when "conditional"
      convert_conditional(node)
    when "var"
      convert_var(node)
    when "instance_var"
      Crystal::InstanceVar.new(text(node))
    when "assign", "const_assign"
      convert_assign(node)
    when "expressions", "ERROR", "then"
      convert_expressions(node)
    when "method_def"
      convert_def(node)
    when "integer"
      Crystal::NumberLiteral.new(text(node))
    when "or"
      convert_or(node)
    when "identifier"
      Crystal::Var.new(text(node))
    when "constant"
      Crystal::Path.new(text(node).split("::"))
    when "array"
      convert_array(node)
    when "named_expr"
      convert_named_expr(node)
    when "regex"
      Crystal::RegexLiteral.new(
        Crystal::StringLiteral.new(
          text(node.child(1)) == "/" ? "" : text(node.child(1))))
    when "if"
      convert_if(node)
    when "while"
      convert_while(node)
    when "case"
      convert_case(node)
    when "when", "in"
      convert_when(node, node.type == "in")
    when "else"
      convert_node?(child_by_field_name(node, "body"))
    when "not"
      Crystal::Not.new(convert_node?(node.child(1)))
    when "(", ")", "[", "]", ",", "comment", "of", "end"
      # SKIP
    when "pseudo_constant"
      Crystal::MagicConstant.new case text(node)
      when "__FILE__"
        Crystal::Token::Kind::MAGIC_FILE
      when "__DIR__"
        Crystal::Token::Kind::MAGIC_DIR
      when "__END_LINE__"
        Crystal::Token::Kind::MAGIC_END_LINE
      when "__LINE__"
        Crystal::Token::Kind::MAGIC_LINE
      else
        Crystal::Token::Kind::MAGIC_FILE
      end
    when "generic_instance_type"
      convert_generic_instance_type(node)
    else
      puts "cannot convert #{node.type}"
      Crystal::Nop.new
    end.try(&.at(pos(node)).at_end(end_pos(node)))
  end

  def convert_node?(node : TreeSitter::Node?) : Crystal::ASTNode?
    node ? convert_node(node) || Crystal::Nop.new : Crystal::Nop.new
  end

  private def convert_require(node) : Crystal::Require
    Crystal::Require.new(text(node.child(1))[1..-2])
  end

  private def convert_bool(node) : Crystal::BoolLiteral
    Crystal::BoolLiteral.new(node.type == "true")
  end

  def convert_var(node) : Crystal::Var
    Crystal::Var.new(text(node))
  end

  private def convert_class_def(node : TreeSitter::Node) : Crystal::ClassDef
    name_node = child_by_field_name(node, "name")
    body_node = child_by_field_name(node, "body")

    name = name_node ? Crystal::Path.new(text(name_node)) : Crystal::Path.new("")
    body = body_node ? convert_node(body_node) || Crystal::Nop.new : Crystal::Nop.new

    Crystal::ClassDef.new(name, body)
  end

  private def convert_call(node : TreeSitter::Node) : Crystal::Call
    receiver = child_by_field_name(node, "receiver")
    name = child_by_field_name(node, "method")
    args = child_by_field_name(node, "arguments")

    obj = receiver ? convert_node(receiver) : nil
    call_name = name ? text(name) : ""
    arguments = [] of Crystal::ASTNode

    if args
      args.child_count.times do |i|
        child = args.child(i.to_i32)

        if (ast_arg = convert_node(child))
          arguments << ast_arg
        end
      end
    end

    Crystal::Call.new(obj, call_name, arguments)
  end

  private def convert_implicit_object_call(node) : Crystal::Call
    recv = Crystal::ImplicitObj.new
    name_node = child_by_field_name(node, "method")
    args_node = child_by_field_name(node, "arguments")

    call_name = name_node ? text(name_node)[1..] : ""
    args = [] of Crystal::ASTNode

    if args_node
      args_node.child_count.times do |i|
        child_node = args_node.child(i.to_i32)

        if (child = convert_node(child_node))
          args << child
        end
      end
    end

    Crystal::Call.new(recv, call_name, args)
  end

  private def convert_assign(node : TreeSitter::Node) : Crystal::Assign
    target = child_by_field_name(node, "lhs")
    value = child_by_field_name(node, "rhs")

    target_node = target ? convert_node(target) : Crystal::Nop.new
    target_node ||= Crystal::Nop.new
    value_node = value ? convert_node(value) : Crystal::Nop.new
    value_node ||= Crystal::Nop.new

    Crystal::Assign.new(target_node, value_node)
  end

  private def convert_expressions(node : TreeSitter::Node) : Crystal::Expressions
    expressions = [] of Crystal::ASTNode

    node.child_count.times do |i|
      child = node.child(i.to_i32)

      if (converted_child = convert_node(child))
        expressions << converted_child
      end
    end

    Crystal::Expressions.new(expressions)
  end

  private def convert_def(node : TreeSitter::Node) : Crystal::Def
    # Get the required fields from the tree-sitter node
    recv_node = child_by_field_name(node, "class")
    name_node = child_by_field_name(node, "name")
    body_node = child_by_field_name(node, "body")
    params_node = child_by_field_name(node, "parameters")

    if recv_node
      if (recv_name = text(recv_node))[0]?.try &.uppercase?
        recv = Crystal::Path.new(recv_name.split("::"))
      else
        recv = Crystal::Var.new(recv_name)
      end
    else
      recv = nil
    end

    # Convert method name
    name = name_node ? text(name_node) : ""

    # Convert parameters
    args = [] of Crystal::Arg
    if params_node
      params_node.child_count.times do |i|
        param = params_node.child(i.to_i32)
        next unless param.type == "parameter"
        param_name_node = child_by_field_name(param, "name")
        if param_name_node
          args << Crystal::Arg.new(text(param_name_node))
        end
      end
    end

    # Convert body
    body = if body_node
             convert_node(body_node) || Crystal::Nop.new
           else
             Crystal::Nop.new
           end

    # Create the method definition node
    Crystal::Def.new(
      name: name,
      args: args,
      body: body,
      receiver: recv,
      block_arg: nil,
      return_type: nil,
      free_vars: nil
    )
  end

  private def convert_type_declaration(node) : Crystal::TypeDeclaration
    var_node = child_by_field_name(node, "var")
    type_node = child_by_field_name(node, "type")
    value_node = child_by_field_name(node, "value")

    var = var_node ? convert_node(var_node) || Crystal::Nop.new : Crystal::Nop.new
    type = type_node ? convert_node(type_node) || Crystal::Nop.new : Crystal::Nop.new
    value = convert_node(value_node) if value_node

    Crystal::TypeDeclaration.new(var, type, value)
  end

  private def convert_named_expr(node) : Crystal::NamedArgument
    name_node = child_by_field_name(node, "name")
    name = name_node ? text(name_node) : ""

    value_node = node.child(2)
    value = value_node ? convert_node(value_node) || Crystal::Nop.new : Crystal::Nop.new

    Crystal::NamedArgument.new(name, value)
  end

  private def convert_conditional(node) : Crystal::If
    cond_node = child_by_field_name(node, "cond")
    then_node = child_by_field_name(node, "then")
    else_node = child_by_field_name(node, "else")

    cond_ = convert_node?(cond_node)
    then_ = convert_node?(then_node)
    else_ = convert_node?(else_node)

    Crystal::If.new(cond_, then_, else_, true)
  end

  private def convert_or(node) : Crystal::Or
    left_node = node.child(0)
    right_node = node.child(2)

    left = convert_node?(left_node)
    right = convert_node?(right_node)

    Crystal::Or.new(left, right)
  end

  private def convert_array(node) : Crystal::ArrayLiteral
    elements = [] of Crystal::ASTNode

    if child_by_field_name(node, "of")
      type_node = node.child((node.child_count - 1).to_i32)
      type = convert_node?(type_node)
    end

    node.child_count.times do |i|
      next if (i == node.child_count - 1) && type
      child_node = node.child(i.to_i32)

      if (child = convert_node(child_node))
        next if child.is_a?(Crystal::Nop)
        elements << child
      end
    end

    Crystal::ArrayLiteral.new(elements, type)
  end

  private def convert_if(node) : Crystal::If
    cond_node = child_by_field_name(node, "cond")
    then_node = child_by_field_name(node, "then")
    else_node = child_by_field_name(node, "else")

    cond_ = convert_node?(cond_node)
    then_ = convert_node?(then_node)
    else_ = convert_node?(else_node)

    Crystal::If.new(cond_, then_, else_, false)
  end

  private def convert_while(node) : Crystal::While
    cond_node = child_by_field_name(node, "cond")
    body_node = child_by_field_name(node, "body")

    cond = convert_node?(cond_node)
    body = convert_node?(body_node)

    Crystal::While.new(cond, body)
  end

  private def convert_case(node) : Crystal::Case
    cond_node = child_by_field_name(node, "cond")
    cond = convert_node(cond_node) if cond_node

    whens = [] of Crystal::When
    else_ = nil

    node.child_count.times do |i|
      case (child = convert_node(node.child(i.to_i32)))
      when Crystal::When
        whens << child
      when Crystal::Nop
      else
        else_ = child
      end
    end

    Crystal::Case.new(cond, whens, else_, !!whens.first?.try(&.exhaustive?))
  end

  private def convert_when(node, exhaustive) : Crystal::When
    cond_node = child_by_field_name(node, "cond")
    cond = convert_node?(cond_node)

    body_node = child_by_field_name(node, "body")
    body = convert_node?(body_node)

    Crystal::When.new(cond, body, exhaustive)
  end

  private def convert_generic_instance_type(node) : Crystal::Generic
    name_node = node.child(0)
    name = convert_node?(name_node)

    type_vars = [] of Crystal::ASTNode

    node.child_count.times do |i|
      child_node = node.child(i.to_i32)

      case (child = convert_node(child_node))
      when Crystal::Nop, nil
      else
        type_vars << child
      end
    end

    Crystal::Generic.new(name, type_vars)
  end

  # Get the node's child with the given field name.
  #
  # Field names are defined in the grammar for nodes that have named children.
  # Returns nil if no child exists for the given field name.
  def child_by_field_name(node, field_name : String) : TreeSitter::Node?
    ptr = LibTreeSitter.ts_node_child_by_field_name(
      node.to_unsafe,
      field_name,
      field_name.bytesize
    )

    # Check if the returned node is null
    if LibTreeSitter.ts_node_is_null(ptr)
      nil
    else
      TreeSitter::Node.new(ptr)
    end
  end

  def text(node)
    node.text(source).strip
  end

  def pos(node) : Crystal::Location
    point = node.start_point
    Crystal::Location.new(@path, line_number: point.row.to_i32, column_number: point.column.to_i32)
  end

  def end_pos(node) : Crystal::Location
    point = node.end_point
    Crystal::Location.new(@path, line_number: point.row.to_i32, column_number: point.column.to_i32)
  end
end

converter = TreeSitterConverter.new
source = File.read("src/parser/parser.cr")
# source = <<-SRC
# class Name
#   def foo
#   end
# SRC

puts source
puts "\n------------------------------------------------\n\n"
puts converter.parse("src/parser/parser.cr", source)
