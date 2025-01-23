class TreeSitterProvider < Provider
  Log = ::Larimar::Log.for(self)

  include SemanticTokensProvider
  include FoldingRangeProvider

  CrystalParser = TreeSitter::Parser.new("crystal")

  def provide_semantic_tokens(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(SemanticToken)?
    tree = CrystalParser.parse(nil, document.to_s)

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
      next unless type = LSProtocol::SemanticTokenTypes.parse?(capture.rule)

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

  def provide_folding_ranges(
    document : Larimar::TextDocument,
    token : CancellationToken?,
  ) : Array(LSProtocol::FoldingRange)?
    tree = CrystalParser.parse(nil, document.to_s)

    query = TreeSitter::Query.new(
      CrystalParser.language,
      File.read("#{__DIR__}/../../queries/folds.scm")
    )

    cursor = TreeSitter::QueryCursor.new(query)
    cursor.exec(tree.root_node)

    folds = Array(LSProtocol::FoldingRange).new

    cursor.each_capture do |capture|
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
end
