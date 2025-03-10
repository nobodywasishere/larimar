class TreeSitterProvider < Provider
  Log = ::Larimar::Log.for(self)

  # include SemanticTokensProvider
  # include SemanticTokensRangeProvider
  include FoldingRangeProvider
  include DocumentSymbolProvider

  CrystalParser = TreeSitter::Parser.new("crystal")

  @forest : Hash({URI, Int32}, TreeSitter::Tree) = Hash({URI, Int32}, TreeSitter::Tree).new
  @forest_mutex : RWLock = RWLock.new

  def provide_semantic_tokens(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(SemanticToken)?
    tree = get_cached_tree(document)

    query = TreeSitter::Query.new(
      CrystalParser.language,
      File.read("#{__DIR__}/../../queries/highlights.scm")
    )

    cursor = TreeSitter::QueryCursor.new(query)
    cursor.exec(tree.root_node)

    tokens = Array(SemanticToken).new

    line_diff = 0
    colm_diff = 0
    prev_position = LSProtocol::Position.new(0, 0)

    cursor.each_capture do |capture|
      return tokens if token.try(&.cancelled?)

      next unless (type = LSProtocol::SemanticTokenTypes.parse?(capture.rule))

      position = LSProtocol::Position.new(
        line: capture.node.start_point.row.to_u32,
        character: capture.node.start_point.column.to_u32
      ) rescue nil

      if position.nil?
        next
      end

      line_diff = position.line - prev_position.line
      if line_diff > 0
        colm_diff = position.character
      else
        colm_diff = position.character - prev_position.character
      end

      prev_position = position

      tokens << SemanticToken.new(
        line: line_diff.to_i32, char: colm_diff.to_i32,
        size: (capture.node.end_byte - capture.node.start_byte).to_i32,
        type: type, mods: :none
      )
    end

    tokens
  end

  def provide_semantic_tokens_range(
    document : Larimar::TextDocument,
    range : LSProtocol::Range,
    token : CancellationToken?,
    & : Array(SemanticToken) -> Nil
  ) : Array(SemanticToken)?
    tree = get_cached_tree(document)

    query = TreeSitter::Query.new(
      CrystalParser.language,
      File.read("#{__DIR__}/../../queries/highlights.scm")
    )

    cursor = TreeSitter::QueryCursor.new(query)
    cursor.exec(tree.root_node)

    tokens = Array(SemanticToken).new

    line_diff = 0
    colm_diff = 0
    prev_position = LSProtocol::Position.new(0, 0)

    cursor.each_capture do |capture|
      return tokens if token.try(&.cancelled?)

      next unless (type = LSProtocol::SemanticTokenTypes.parse?(capture.rule))

      position = LSProtocol::Position.new(
        line: capture.node.start_point.row.to_u32,
        character: capture.node.start_point.column.to_u32
      ) rescue nil

      if position.nil? || !range_contains?(range, position)
        next
      end

      line_diff = position.line - prev_position.line
      if line_diff > 0
        colm_diff = position.character
      else
        colm_diff = position.character - prev_position.character
      end

      prev_position = position

      tokens << SemanticToken.new(
        line: line_diff.to_i32, char: colm_diff.to_i32,
        size: (capture.node.end_byte - capture.node.start_byte).to_i32,
        type: type, mods: :none
      )

      if line_diff > 0
        yield tokens
        tokens.clear
      end
    end

    yield tokens
    tokens.clear

    tokens
  end

  def provide_folding_ranges(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(LSProtocol::FoldingRange)?
    tree = get_cached_tree(document)

    query = TreeSitter::Query.new(
      CrystalParser.language,
      File.read("#{__DIR__}/../../queries/folds.scm")
    )

    cursor = TreeSitter::QueryCursor.new(query)
    cursor.exec(tree.root_node)

    folds = Array(LSProtocol::FoldingRange).new

    cursor.each_capture do |capture|
      return folds if token.try(&.cancelled?)

      next unless capture.rule.starts_with?("fold")

      folds << LSProtocol::FoldingRange.new(
        start_line: capture.node.start_point.row.to_u32,
        start_character: capture.node.start_point.column.to_u32,
        end_line: capture.node.end_point.row.to_u32,
        end_character: capture.node.end_point.column.to_u32,
        kind: capture.rule.lchop?("fold.")
      )
    end

    folds
  end

  def provide_document_symbols(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(LSProtocol::DocumentSymbol)?
    source = document.to_s
    tree = get_cached_tree(document)

    query = TreeSitter::Query.new(
      CrystalParser.language,
      File.read("#{__DIR__}/../../queries/outline.scm")
    )

    cursor = TreeSitter::QueryCursor.new(query)
    cursor.exec(tree.root_node)

    symbols = Array(LSProtocol::DocumentSymbol).new
    symbol_stack = Array(LSProtocol::DocumentSymbol).new

    curr_kind : LSProtocol::SymbolKind = LSProtocol::SymbolKind::Variable
    curr_names = %w[]
    curr_range = nil
    curr_selection_range = nil
    curr_details = %w[]

    cursor.each_capture do |capture|
      return symbols if token.try(&.cancelled?)

      case capture.rule
      when "context"
        curr_details << capture.text(source).strip
      when "name"
        curr_names << capture.text(source).strip
        curr_selection_range = ts_node_to_range(capture.node)
      else
        handle_new_symbol()

        curr_kind = LSProtocol::SymbolKind::Variable
        curr_names.clear
        curr_range = nil
        curr_selection_range = nil
        curr_details.clear

        # create new item
        curr_kind = capture.rule.lchop?("item.").try { |i| LSProtocol::SymbolKind.parse?(i) } ||
                    LSProtocol::SymbolKind::Variable
        curr_range = ts_node_to_range(capture.node)
      end
    end

    handle_new_symbol()

    symbols
  end

  private def get_cached_tree(document : Larimar::TextDocument) : TreeSitter::Tree
    @forest_mutex.write do
      if @forest.has_key?({document.uri, document.version})
        @forest[{document.uri, document.version}]
      else
        @forest[{document.uri, document.version}] = CrystalParser.parse(nil, document.to_s)
      end
    end
  end

  private def ts_node_to_range(node : TreeSitter::Node) : LSProtocol::Range
    LSProtocol::Range.new(
      start: LSProtocol::Position.new(
        line: node.start_point.row.to_u32,
        character: node.start_point.column.to_u32
      ),
      end: LSProtocol::Position.new(
        line: node.end_point.row.to_u32,
        character: node.end_point.column.to_u32
      )
    )
  end

  # Helper method to check if one range contains another
  private def range_contains?(outer : LSProtocol::Range, inner : LSProtocol::Range) : Bool
    # Compare start and end positions of the ranges
    position_less_or_equal?(outer.start, inner.start) &&
      position_less_or_equal?(inner.end, outer.end)
  end

  private def range_contains?(outer : LSProtocol::Range, inner : LSProtocol::Position) : Bool
    position_less_or_equal?(outer.start, inner) &&
      position_less_or_equal?(outer.end, inner)
  end

  # Helper method to compare two positions
  private def position_less_or_equal?(pos1 : LSProtocol::Position, pos2 : LSProtocol::Position) : Bool
    pos1.line < pos2.line || (pos1.line == pos2.line && pos1.character <= pos2.character)
  end

  macro handle_new_symbol
    curr_selection_range ||= curr_range
    if curr_names && curr_range && curr_selection_range
      curr_selection_range = curr_range unless range_contains?(curr_range, curr_selection_range)

      # append old item
      new_symbol = LSProtocol::DocumentSymbol.new(
        kind: curr_kind,
        name: !curr_names.empty? ? curr_names.join("") : "Unknown symbol name",
        range: curr_range,
        selection_range: curr_selection_range,
        detail: curr_details.join(" "),
        children: [] of LSProtocol::DocumentSymbol
      )

      # Determine where to place the new symbol
      while !symbol_stack.empty? && !range_contains?(symbol_stack.last.range, curr_range)
        # Pop symbols that are no longer parents
        symbol_stack.pop
      end

      if !symbol_stack.empty?
        # Add as a child of the current parent
        parent = symbol_stack.last
        parent.children.try(&.<<(new_symbol))
      else
        # Add as a top-level symbol
        symbols << new_symbol
      end

      # Push the new symbol onto the stack
      symbol_stack << new_symbol
    end
  end
end
