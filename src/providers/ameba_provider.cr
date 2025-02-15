# TODO: remove this monkey-patch
class Ameba::Config
  property sources : Array(Source)?

  def sources
    @sources ||= if (file = stdin_filename)
                   [Source.new(STDIN.gets_to_end, file)]
                 else
                   (find_files_by_globs(globs) - find_files_by_globs(excluded))
                     .map { |path| Source.new File.read(path), path }
                 end
  end
end

class AmebaProvider < Provider
  Log = ::Larimar::Log.for(self)

  include CodeActionProvider

  getter issue_hash : Hash(String, Ameba::Issue) = Hash(String, Ameba::Issue).new

  class DiagnosticsFormatter < Ameba::Formatter::BaseFormatter
    getter diagnostics : Array(LSProtocol::Diagnostic) = Array(LSProtocol::Diagnostic).new
    getter issue_hash : Hash(String, Ameba::Issue) = Hash(String, Ameba::Issue).new

    @mutex : Mutex = Mutex.new
    property cancellation_token : CancellationToken?

    def source_finished(source : Ameba::Source) : Nil
      source.issues.each do |issue|
        cancellation_token.try &.cancelled!

        start_location = LSProtocol::Position.new(
          line: Math.max(issue.location.try(&.line_number.to_u32) || 1_u32, 1_u32) - 1,
          character: Math.max(issue.location.try(&.column_number.to_u32) || 1_u32, 1_u32) - 1,
        )

        end_location = LSProtocol::Position.new(
          line: Math.max(
            issue.end_location.try(&.line_number.to_u32) ||
            issue.location.try(&.line_number.to_u32) ||
            1_u32,
            1_u32
          ) - 1,
          character: issue.end_location.try(&.column_number.to_u32) ||
                     issue.location.try(&.column_number.to_u32) ||
                     1_u32,
        )

        @mutex.synchronize do
          hash = issue.hash.to_s
          issue_hash[hash] = issue

          diagnostics << LSProtocol::Diagnostic.new(
            code: "ameba-issue",
            message: "[#{issue.rule.name}] #{issue.message}",
            range: LSProtocol::Range.new(
              start: start_location,
              end: end_location
            ),
            severity: convert_severity(issue.rule.severity),
            data: JSON::Any.new(hash)
          )
        end
      end
    end

    def convert_severity(severity : Ameba::Severity) : LSProtocol::DiagnosticSeverity
      case severity
      in .error?
        LSProtocol::DiagnosticSeverity::Error
      in .warning?
        LSProtocol::DiagnosticSeverity::Warning
      in .convention?
        LSProtocol::DiagnosticSeverity::Information
      end
    end
  end

  def on_open(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_change(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_save(document : Larimar::TextDocument) : Nil
    handle_ameba(document)
  end

  def on_close(document : Larimar::TextDocument) : Nil
    controller.server.send_msg(
      LSProtocol::PublishDiagnosticsNotification.new(
        params: LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: [] of LSProtocol::Diagnostic,
          uri: document.uri
        )
      )
    )
  end

  private def handle_ameba(document : Larimar::TextDocument) : Nil
    source = Ameba::Source.new(document.to_s, document.uri.path)
    formatter = DiagnosticsFormatter.new

    config_path : String? = nil

    workspace_folder : String? = Larimar::Workspace.find_closest_shard_yml(document.uri).try(&.path)
    if workspace_folder
      test_path : Path? = Path.new(workspace_folder, ".ameba.yml")
      config_path = test_path.to_s
    end

    Log.debug(&.emit("Running ameba", source: document.uri.path, config: config_path))

    config = Ameba::Config.load(path: config_path)
    config.sources = [source]
    config.formatter = formatter

    # Disabling these as they're common when typing
    config.update_rules(%w(Lint/Formatting Layout/TrailingBlankLines Layout/TrailingWhitespace), enabled: false)

    begin
      Ameba::Runner.new(config).run
    rescue CancellationException
    end

    @issue_hash = formatter.issue_hash

    controller.server.send_msg(
      LSProtocol::PublishDiagnosticsNotification.new(
        params: LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: formatter.diagnostics,
          uri: document.uri
        )
      )
    )
  end

  def provide_code_actions(
    document : Larimar::TextDocument,
    range : LSProtocol::Range | LSProtocol::SelectionRange,
    context : LSProtocol::CodeActionContext,
    token : CancellationToken?,
  ) : Array(LSProtocol::Command | LSProtocol::CodeAction)?
    code_actions = Array(LSProtocol::CodeAction | LSProtocol::Command).new

    context.diagnostics.each do |diagnostic|
      if diagnostic.code == "ameba-issue"
        issue_id = diagnostic.data.try(&.as_s?)
        next unless (issue = issue_hash[issue_id]?)

        action = LSProtocol::CodeAction.new(
          title: "Fix #{issue.rule.name}",
          kind: LSProtocol::CodeActionKind::QuickFix,
          diagnostics: [diagnostic]
        )

        code_actions << action
      end
    end

    code_actions
  end

  def resolve_code_action(
    code_action : LSProtocol::CodeAction,
    token : CancellationToken?,
  ) : LSProtocol::CodeAction?
    issue_id = code_action.data.try(&.as_s?).try(&.to_u32?)
    issue = issue_hash[issue_id]?

    return unless issue

    corrector = CodeActionCorrector.new

    issue.correct(corrector)

    return unless (filename = corrector.filename)

    LSProtocol::CodeAction.new(
      title: "[#{issue.rule.name}] #{issue.message}",
      edit: LSProtocol::WorkspaceEdit.new(
        changes: {
          URI.parse(filename) => corrector.text_edits,
        }
      )
    )
  end
end

class CodeActionCorrector < Ameba::Source::Corrector
  getter filename : String?
  getter text_edits : Array(LSProtocol::TextEdit) = Array(LSProtocol::TextEdit).new

  def initialize
    super("")
  end

  # Replaces the code of the given range with *content*.
  def replace(location, end_location, content)
    # @rewriter.replace(loc_to_pos(location), loc_to_pos(end_location) + 1, content)
    # text_edits << LSProtocol::TextEdit.new(
    #   new_text: content.to_s,
    #   range: LSProtocol::Range.new(
    #     start: ls_loc(location),
    #     end: ls_loc(end_location)
    #   )
    # )
  end

  # :ditto:
  def replace(range : Range(Int32, Int32), content)
    # begin_pos, end_pos = range.begin, range.end
    # end_pos -= 1 unless range.excludes_end?
    # @rewriter.replace(begin_pos, end_pos, content)
  end

  # Inserts the given strings before and after the given range.
  def wrap(location, end_location, insert_before, insert_after)
    # @rewriter.wrap(loc_to_pos(location), loc_to_pos(end_location) + 1, insert_before, insert_after)
  end

  # :ditto:
  def wrap(range : Range(Int32, Int32), insert_before, insert_after)
    # begin_pos, end_pos = range.begin, range.end
    # end_pos -= 1 unless range.excludes_end?
    # @rewriter.wrap(begin_pos, end_pos, insert_before, insert_after)
  end

  # Shortcut for `replace(location, end_location, "")`
  def remove(location, end_location)
    # @rewriter.remove(loc_to_pos(location), loc_to_pos(end_location) + 1)
  end

  # Shortcut for `replace(range, "")`
  def remove(range : Range(Int32, Int32))
    # begin_pos, end_pos = range.begin, range.end
    # end_pos -= 1 unless range.excludes_end?
    # @rewriter.remove(begin_pos, end_pos)
  end

  # Shortcut for `wrap(location, end_location, content, nil)`
  def insert_before(location, end_location, content)
    # @rewriter.insert_before(loc_to_pos(location), loc_to_pos(end_location) + 1, content)
  end

  # Shortcut for `wrap(range, content, nil)`
  def insert_before(range : Range(Int32, Int32), content)
    # begin_pos, end_pos = range.begin, range.end
    # end_pos -= 1 unless range.excludes_end?
    # @rewriter.insert_before(begin_pos, end_pos, content)
  end

  # Shortcut for `wrap(location, end_location, nil, content)`
  def insert_after(location, end_location, content)
    # @rewriter.insert_after(loc_to_pos(location), loc_to_pos(end_location) + 1, content)
  end

  # Shortcut for `wrap(range, nil, content)`
  def insert_after(range : Range(Int32, Int32), content)
    # begin_pos, end_pos = range.begin, range.end
    # end_pos -= 1 unless range.excludes_end?
    # @rewriter.insert_after(begin_pos, end_pos, content)
  end

  # Shortcut for `insert_before(location, location, content)`
  def insert_before(location, content)
    # @rewriter.insert_before(loc_to_pos(location), content)
  end

  # Shortcut for `insert_before(pos.., content)`
  def insert_before(pos : Int32, content)
    # @rewriter.insert_before(pos, content)
  end

  # Shortcut for `insert_after(location, location, content)`
  def insert_after(location, content)
    # @rewriter.insert_after(loc_to_pos(location) + 1, content)
  end

  # Shortcut for `insert_after(...pos, content)`
  def insert_after(pos : Int32, content)
    # @rewriter.insert_after(pos, content)
  end

  # Removes *size* characters prior to the source range.
  def remove_preceding(location, end_location, size)
    # @rewriter.remove(loc_to_pos(location) - size, loc_to_pos(location))
  end

  # :ditto:
  def remove_preceding(range : Range(Int32, Int32), size)
    # begin_pos = range.begin
    # @rewriter.remove(begin_pos - size, begin_pos)
  end

  # Removes *size* characters from the beginning of the given range.
  # If *size* is greater than the size of the range, the removed region can
  # overrun the end of the range.
  def remove_leading(location, end_location, size)
    # @rewriter.remove(loc_to_pos(location), loc_to_pos(location) + size)
  end

  # :ditto:
  def remove_leading(range : Range(Int32, Int32), size)
    # begin_pos = range.begin
    # @rewriter.remove(begin_pos, begin_pos + size)
  end

  # Removes *size* characters from the end of the given range.
  # If *size* is greater than the size of the range, the removed region can
  # overrun the beginning of the range.
  def remove_trailing(location, end_location, size)
    # @rewriter.remove(loc_to_pos(end_location) + 1 - size, loc_to_pos(end_location) + 1)
  end

  # :ditto:
  def remove_trailing(range : Range(Int32, Int32), size)
    # end_pos = range.end
    # end_pos -= 1 unless range.excludes_end?
    # @rewriter.remove(end_pos - size, end_pos)
  end

  # Replaces the code of the given node with *content*.
  def replace(node : Crystal::ASTNode, content)
    # replace(location(node), end_location(node), content)
  end

  # Inserts the given strings before and after the given node.
  def wrap(node : Crystal::ASTNode, insert_before, insert_after)
    # wrap(location(node), end_location(node), insert_before, insert_after)
  end

  # Shortcut for `replace(node, "")`
  def remove(node : Crystal::ASTNode)
    # remove(location(node), end_location(node))
  end

  # Shortcut for `wrap(node, content, nil)`
  def insert_before(node : Crystal::ASTNode, content)
    # insert_before(location(node), content)
  end

  # Shortcut for `wrap(node, nil, content)`
  def insert_after(node : Crystal::ASTNode, content)
    # insert_after(end_location(node), content)
  end

  # Removes *size* characters prior to the given node.
  def remove_preceding(node : Crystal::ASTNode, size)
    # remove_preceding(location(node), end_location(node), size)
  end

  # Removes *size* characters from the beginning of the given node.
  # If *size* is greater than the size of the node, the removed region can
  # overrun the end of the node.
  def remove_leading(node : Crystal::ASTNode, size)
    # remove_leading(location(node), end_location(node), size)
  end

  # Removes *size* characters from the end of the given node.
  # If *size* is greater than the size of the node, the removed region can
  # overrun the beginning of the node.
  def remove_trailing(node : Crystal::ASTNode, size)
    # remove_trailing(location(node), end_location(node), size)
  end

  private def loc_to_pos(location : Crystal::Location | {Int32, Int32})
    if location.is_a?(Crystal::Location)
      line, column = location.line_number, location.column_number
    else
      line, column = location
    end
    @line_sizes[0...line - 1].sum + (column - 1)
  end

  private def ls_loc(loc : Crystal::Location | Tuple(Int32, Int32)) : LSProtocol::Position
    if location.is_a?(Crystal::Location)
      @filename ||= loc.original_filename
      line, column = location.line_number, location.column_number
    else
      line, column = location
    end

    LSProtocol::Position.new(
      line: line.to_u32,
      character: column.to_u32
    )
  end

  private def ls_loc(node : Crystal::ASTNode) : LSProtocol::Position
    if (loc = node.location).nil?
      raise "Missing location"
    end

    @filename ||= loc.original_filename

    LSProtocol::Position.new(
      line: loc.line_number.to_u32,
      character: loc.column_number.to_u32
    )
  end

  private def ls_end_loc(node : Crystal::ASTNode) : LSProtocol::Position
    if (loc = node.end_location).nil?
      raise "Missing location"
    end

    @filename ||= loc.original_filename

    LSProtocol::Position.new(
      line: loc.line_number.to_u32,
      character: loc.column_number.to_u32
    )
  end
end
