class Larimar::SemanticTokensVisitor < Crystal::Visitor
  record(
    SemanticToken,
    line : Int32,
    char : Int32,
    size : Int32,
    type : LSProtocol::SemanticTokenTypes,
    mods : LSProtocol::SemanticTokenModifiers = :none
  ) do
    def to_a : Array(UInt32)
      [
        @line.to_u32,
        @char.to_u32,
        @size.to_u32,
        @type.value.to_u32,
        @mods.value.to_u32,
      ]
    end
  end

  getter semantic_tokens = Array(SemanticToken).new
  getter diagnostics = Array(LSProtocol::Diagnostic).new

  @previous_node : Crystal::ASTNode?

  def visit(node)
    # prev = @previous_node.try(&.location) || Crystal::Location.new("", 0, 0)

    # case node
    # in Crystal::Path
    #   if token = node_to_token(node, prev, :namespace)
    #     @semantic_tokens << token
    #   end
    # in Crystal::ASTNode
    #   if token = node_to_token(node, prev)
    #     @semantic_tokens << token
    #   end
    # end

    # @previous_node = node

    true
  end

  def visit(node : Crystal::ClassDef)
    # location = node.location
    # return if location.nil?

    # if node.abstract?
    #   @semantic_tokens << SemanticToken.new(
    #     line: location.line_number,
    #     char: location.column_number,
    #     size: "abstract".size,
    #     type: :
    #   )
    # end

    true
  end

  def visit(node : Crystal::Path)
    return if (loc = node.location).nil? || (end_loc = node.end_location).nil?
    line = loc.line_number
    char = loc.column_number
    end_line = end_loc.line_number
    end_char = end_loc.column_number

    return if line.nil? || char.nil? || end_line.nil? || end_char.nil?

    @semantic_tokens << SemanticToken.new(
      line: line - 1,
      char: char - 1,
      size: node.name_size,
      type: LSProtocol::SemanticTokenTypes::Namespace
    )

    @diagnostics << LSProtocol::Diagnostic.new(
      message: "#{node.names.join("::")} - #{node.name_size} - #{line}:#{char}",
      severity: LSProtocol::DiagnosticSeverity::Information,
      range: LSProtocol::Range.new(
        start: LSProtocol::Position.new(
          line: (line - 1).to_u32,
          character: (char - 1).to_u32
        ),
        end: LSProtocol::Position.new(
          line: (end_line - 1).to_u32,
          character: end_char.to_u32
        )
      )
    )

    true
  end

  private def node_to_token(
    node : Crystal::ASTNode, prev : Crystal::Location,
    type : LSProtocol::SemanticTokenTypes = :type,
    mods : LSProtocol::SemanticTokenModifiers = :none
  ) : SemanticToken?
    curr = node.location
    cend = node.end_location
    return if curr.nil?

    # SemanticToken.new(
    #   line: curr.line_number - prev.line_number,
    #   char: curr.column_number - prev.column_number,
    #   size: cend,
    #   type: type,
    #   mods: mods
    # )
  end
end
