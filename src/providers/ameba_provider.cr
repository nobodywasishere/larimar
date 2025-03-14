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

  class DiagnosticsFormatter < Ameba::Formatter::BaseFormatter
    getter diagnostics : Array(LSProtocol::Diagnostic) = Array(LSProtocol::Diagnostic).new
    @mutex : Mutex = Mutex.new
    property cancellation_token : CancellationToken?

    def source_finished(source : Ameba::Source) : Nil
      source.issues.each do |issue|
        cancellation_token.try &.cancelled!

        start_location = LSProtocol::Position.new(
          line: (issue.location.try(&.line_number.to_u32) || 1_u32) - 1,
          character: (issue.location.try(&.column_number.to_u32) || 1_u32) - 1,
        )

        end_location = LSProtocol::Position.new(
          line: (issue.end_location.try(&.line_number.to_u32) || issue.location.try(&.line_number.to_u32) || 1_u32) - 1,
          character: (issue.end_location.try(&.column_number.to_u32) || issue.location.try(&.column_number.to_u32) || 1_u32),
        )

        @mutex.synchronize do
          diagnostics << LSProtocol::Diagnostic.new(
            message: "[#{issue.rule.name}] #{issue.message}",
            range: LSProtocol::Range.new(
              start: start_location,
              end: end_location
            ),
            severity: convert_severity(issue.rule.severity)
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

      if File.exists?(test_path)
        config_path = test_path.to_s
      end
    end

    Log.debug(&.emit("Running ameba", source: document.uri.path, config: config_path))

    config = Ameba::Config.load(path: config_path)
    config.sources = [source]
    config.formatter = formatter

    # Disabling these as they're common when typing
    config.update_rules(%w[Lint/Formatting Layout/TrailingBlankLines Layout/TrailingWhitespace], enabled: false)

    begin
      Ameba::Runner.new(config).run
    rescue CancellationException
    end

    controller.server.send_msg(
      LSProtocol::PublishDiagnosticsNotification.new(
        params: LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: formatter.diagnostics,
          uri: document.uri
        )
      )
    )
  end
end
