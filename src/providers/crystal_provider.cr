class CrystalProvider < Provider
  include FormattingProvider
  include InlayHintProvider

  class LocalVarInlayHintRule < Ameba::Rule::Base
    properties do
      description "Finds places to do inlay hints"
    end

    MSG = ""

    @[YAML::Field(ignore: true)]
    getter inlay_hints = Array(LSProtocol::InlayHint).new

    def test(source)
      Ameba::AST::ScopeVisitor.new self, source
    end

    def test(source, node, scope : Ameba::AST::Scope)
      return if scope.lib_def?(check_outer_scopes: true)

      scope.variables.each do |var|
        case var.assign_before_reference
        when Crystal::Assign, Crystal::MultiAssign
          @inlay_hints << to_inlay_hint(var.node)
        end
      end
    end

    def to_inlay_hint(node : Crystal::Var) : LSProtocol::InlayHint
      LSProtocol::InlayHint.new(
        label: ": ?",
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
  end

  def provide_inlay_hints(
    document : Larimar::TextDocument,
    range : LSProtocol::Range,
    token : CancellationToken?,
  ) : Array(LSProtocol::InlayHint)?
    subject = LocalVarInlayHintRule.new

    Ameba::AST::ScopeVisitor.new(subject, document.ameba_source)

    subject.inlay_hints
  rescue Crystal::SyntaxException
  end
end
