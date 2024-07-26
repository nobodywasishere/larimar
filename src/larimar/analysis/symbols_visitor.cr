class Larimar::DocumentSymbolsVisitor < Crystal::Visitor
  getter symbols : Array(LSProtocol::SymbolInformation) = Array(LSProtocol::SymbolInformation).new

  @parent_symbol : LSProtocol::SymbolInformation? = nil
  @parent_macro_call : Crystal::Call? = nil

  def initialize(@document_uri : URI)
  end

  def visit(node)
    true
  end

  def visit(node : Crystal::ClassDef)
    symbol = node_to_symbol(node, :class)
    @symbols << symbol

    with_parent(symbol) do
      node.body.accept(self)
    end

    false
  end

  def visit(node : Crystal::ModuleDef)
    symbol = node_to_symbol(node, :module)
    @symbols << symbol

    with_parent(symbol) do
      node.body.accept(self)
    end

    false
  end

  def visit(node : Crystal::AnnotationDef)
    symbol = node_to_symbol(node, :property)
    @symbols << symbol

    false
  end

  def visit(node : Crystal::EnumDef)
    symbol = node_to_symbol(node, :enum)
    @symbols << symbol

    with_parent(symbol) do
      node.members.each &.accept(self)
    end

    false
  end

  def visit(node : Crystal::LibDef)
    symbol = node_to_symbol(node, :module)
    @symbols << symbol

    with_parent(symbol) do
      node.body.accept(self)
    end

    false
  end

  def visit(node : Crystal::Alias)
    symbol = node_to_symbol(node, :type_parameter)
    @symbols << symbol

    false
  end

  def visit(node : Crystal::Def)
    symbol = node_to_symbol(node, :function, detail: format_def(node))
    @symbols << symbol

    false
  end

  def visit(node : Crystal::Macro)
    symbol = node_to_symbol(node, :method, detail: format_def(node))
    @symbols << symbol

    false
  end

  def visit(node : Crystal::Arg)
    if (@parent_symbol.try &.kind.enum?)
      symbol = node_to_symbol(node, :enum_member)
      @symbols << symbol
    end

    false
  end

  def visit(node : Crystal::Call)
    if (expanded = node.expanded)
      @parent_macro_call = node
      expanded.accept(self)
      @parent_macro_call = nil
    elsif ["getter", "setter", "property"].includes?(node.name.rchop('?').rchop('!'))
      node.args.each &.accept(self)
    elsif node.name == "record"
      type, *params = node.args

      if (block_body = node.block.try(&.body))
        params.push(block_body)
      end

      class_body = Crystal::Expressions.from(params)
      class_def = Crystal::ClassDef.new(type.as(Crystal::Path), class_body, struct: true).at(node)
      class_def.accept(self)
    end

    false
  end

  def visit(node : Crystal::InstanceVar)
    symbol = node_to_symbol(node, :field, detail: format_var(node))
    @symbols << symbol

    false
  end

  def visit(node : Crystal::ClassVar)
    symbol = node_to_symbol(node, :field, detail: format_var(node))
    @symbols << symbol

    false
  end

  def visit(node : Crystal::TypeDeclaration)
    symbol = node_to_symbol(node, :field, format_var(node))
    @symbols << symbol

    false
  end

  def visit(node : Crystal::FunDef)
    symbol = node_to_symbol(node, :method, detail: format_def(node))
    @symbols << symbol

    false
  end

  def visit(node : Crystal::TypeDef)
    symbol = node_to_symbol(node, :type_parameter)
    @symbols << symbol

    false
  end

  def visit(node : Crystal::CStructOrUnionDef)
    symbol = node_to_symbol(node, :class)
    @symbols << symbol

    with_parent(symbol) do
      node.body.accept(self)
    end

    false
  end

  def visit(node : Crystal::Assign)
    if node.target.is_a?(Crystal::Path)
      symbol = node_to_symbol(node, :constant, detail: format_var(node.target))
      @symbols << symbol
    end

    true
  end

  def visit(node : Crystal::Var)
    case @parent_symbol.try(&.kind)
    when Nil
      symbol = node_to_symbol(node, :variable, detail: format_var(node))
    when .class?, .module?
      symbol = node_to_symbol(node, :field, detail: format_var(node))
    else
      symbol = node_to_symbol(node, :variable, detail: format_var(node))
    end

    @symbols << symbol

    true
  end

  def with_parent(symbol : LSProtocol::SymbolInformation, &)
    old_parent = @parent_symbol
    @parent_symbol = symbol
    yield
    @parent_symbol = old_parent
  end

  def node_to_symbol(node : Crystal::ASTNode, kind : LSProtocol::SymbolKind, detail : String? = nil) : LSProtocol::SymbolInformation
    name = node.responds_to?(:name) ? node.name.to_s : node.to_s
    location = node_location(@parent_macro_call || node)

    LSProtocol::SymbolInformation.new(
      kind: kind,
      name: detail || name,
      location: location,
      container_name: @parent_symbol.try(&.name)
    )
  end

  def node_location(node : Crystal::ASTNode) : LSProtocol::Location
    start_loc = node.location
    end_loc = node.end_location || start_loc

    filename = start_loc.try(&.original_filename)
    node_uri = filename ? Path.new(filename).to_uri : @document_uri

    LSProtocol::Location.new(
      uri: node_uri,
      range: LSProtocol::Range.new(
        start: LSProtocol::Position.new(
          line: start_loc.try(&.line_number.-(1).to_u32) || 0_u32,
          character: start_loc.try(&.column_number.-(1).to_u32) || 0_u32
        ),
        end: LSProtocol::Position.new(
          line: end_loc.try(&.line_number.-(1).to_u32) || 0_u32,
          character: end_loc.try(&.column_number.-(1).to_u32) || 0_u32
        )
      )
    )
  end

  def format_def(node : Crystal::Def | Crystal::Macro | Crystal::FunDef) : String
    String.build do |str|
      str << node.name

      if node.args.size > 0 ||
         (node.responds_to?(:block_arg) && node.block_arg) ||
         (node.responds_to?(:double_splat) && node.double_splat)
        str << '('
        printed_arg = false

        node.args.each_with_index do |arg, i|
          str << ", " if printed_arg

          if node.responds_to?(:splat_index)
            str << '*' if node.splat_index == i
          end

          str << arg.to_s
          printed_arg = true
        end

        if node.responds_to?(:double_splat) && (double_splat = node.double_splat)
          str << ", " if printed_arg
          str << "**"
          str << double_splat
          printed_arg = true
        end

        if node.responds_to?(:block_arg) && node.block_arg
          str << ", " if printed_arg
          str << '&'
          printed_arg = true
        end

        str << ')'
      end

      if node.responds_to?(:return_type) && (return_type = node.return_type)
        str << " : #{return_type}"
      end

      if node.responds_to?(:free_vars) && (free_vars = node.free_vars)
        str << " forall "
        free_vars.join(str, ", ")
      end
    end
  end

  def format_var(node) : String
    String.build do |str|
      case node
      when Crystal::TypeDeclaration
        if (var = node.var).responds_to?(:name)
          str << var.name
        else
          str << var
        end

        str << " : " << node.declared_type
      else
        if node.responds_to?(:name)
          str << node.name
        else
          str << node.to_s
        end

        if (type = node.type?)
          str << " : " << type
        end
      end
    end
  end
end
