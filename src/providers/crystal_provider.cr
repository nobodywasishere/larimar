class Larimar::CrystalProvider < Larimar::Provider
  Log = ::Larimar::Log.for(self)

  # include FormattingProvider
  include InlayHintProvider
  include CompletionItemProvider

  CrystalParser = TreeSitter::Parser.new("crystal")

  @forest : Hash({URI, Int32}, TreeSitter::Tree) = Hash({URI, Int32}, TreeSitter::Tree).new
  @forest_mutex : RWLock = RWLock.new

  class LocalVarInlayHintRule < Ameba::Rule::Base
    properties do
      description "Finds places to do inlay hints"
    end

    @[YAML::Field(ignore: true)]
    getter inlay_hints = Array(LSProtocol::InlayHint).new

    @[YAML::Field(ignore: true)]
    property inlay_range : LSProtocol::Range?

    @[YAML::Field(ignore: true)]
    property cancellation_token : CancellationToken?

    def test(source)
      Ameba::AST::ScopeVisitor.new self, source
    end

    def test(source, node, scope : Ameba::AST::Scope)
      cancellation_token.try(&.cancelled!)

      return if scope.lib_def?(check_outer_scopes: true)
      return unless (location = node.location)

      if (range = inlay_range) &&
         ((location.line_number < range.start.line) ||
         ((node.end_location || location).line_number > range.end.line))
        return
      end

      scope.variables.each do |var|
        case var.assign_before_reference
        when Crystal::Assign, Crystal::MultiAssign
          @inlay_hints << to_inlay_hint(var.node)
        end
      end
    end

    def to_inlay_hint(node : Crystal::Var) : LSProtocol::InlayHint
      LSProtocol::InlayHint.new(
        label: " : ?",
        position: LSProtocol::Position.new(
          line: (node.location.try(&.line_number.to_u32) || 1_u32) - 1,
          character: (node.location.try(&.column_number.to_u32) || 2_u32) + node.name.size - 1,
        ),
        padding_left: true,
        padding_right: true
      )
    end
  end

  def provide_document_formatting_edits(
    document : Larimar::TextDocument,
    options : LSProtocol::FormattingOptions,
    token : CancellationToken?,
  ) : Array(LSProtocol::TextEdit)?
    old_contents = document.to_s
    contents : String = Crystal.format(old_contents)

    edit = LSProtocol::TextEdit.new(
      range: LSProtocol::Range.new(
        start: LSProtocol::Position.new(line: 0, character: 0),
        end: LSProtocol::Position.new(line: old_contents.count('\n').to_u32 + 1, character: 0_u32)
      ),
      new_text: contents
    )

    [edit]
  rescue Crystal::SyntaxException
  end

  def provide_inlay_hints(
    document : Larimar::TextDocument,
    range : LSProtocol::Range,
    token : CancellationToken?,
  ) : Array(LSProtocol::InlayHint)?
    subject = LocalVarInlayHintRule.new
    subject.inlay_range = range

    Ameba::AST::ScopeVisitor.new(subject, document.ameba_source)

    subject.inlay_hints
  rescue Crystal::SyntaxException
  end

  class CompletionRule < Ameba::Rule::Base
    properties do
      description ""
    end

    @[YAML::Field(ignore: true)]
    property! location : Crystal::Location

    @[YAML::Field(ignore: true)]
    getter completions : Array(LSProtocol::CompletionItem) = Array(LSProtocol::CompletionItem).new

    @[YAML::Field(ignore: true)]
    property cancellation_token : CancellationToken?

    def test(source, context : Larimar::SemanticContext?)
      return if context.nil?

      Larimar::SemanticVisitor.new self, source, context
    end

    def test(source, node : Crystal::InstanceVar, current_type : Crystal::Type)
      return unless (start_location = node.location)

      Log.info(&.emit("ivar: #{node.name}, loc: #{location}"))

      return unless location.line_number == start_location.line_number

      current_type.all_instance_vars.each do |ivar|
        @completions << LSProtocol::CompletionItem.new(
          label: ivar.name,
          detail: "#{ivar.name} : #{ivar.freeze_type || ivar.type}",
          kind: LSProtocol::CompletionItemKind::Property
        )
      end
    end

    def test(source, node, current_type)
    end
  end

  def provide_completion_items(
    document : Larimar::TextDocument,
    position : LSProtocol::Position,
    token : CancellationToken?,
  ) : Array(LSProtocol::CompletionItem)?
    source = document.to_s
    Log.info(&.emit("generating ts tree context"))
    ts_tree = get_cached_tree(document)
    cr_tree = TreeSitterConverter.new.parse(document.uri.to_s, source, ts_tree)

    Log.info(&.emit("generating semantic context"))
    context = Larimar::SemanticContext.for_entrypoint("src/larimar.cr")

    subject = CompletionRule.new
    subject.location = Crystal::Location.new(document.uri.path, position.line.to_i32, position.character.to_i32)

    Log.info(&.emit("visiting location"))
    visitor = Larimar::SemanticVisitor.new(subject, document, context)
    visitor.visit(cr_tree)

    results = subject.completions

    Log.info(&.emit(results.to_json))
    results
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
end
