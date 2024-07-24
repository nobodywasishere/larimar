class Larimar::Controller
  Log = ::Larimar::Log.for(self)

  @pending_requests : Set(Int32 | String) = Set(Int32 | String).new
  @documents : Hash(URI, Tuple(Larimar::TextDocument, Mutex)) = Hash(URI, Tuple(Larimar::TextDocument, Mutex)).new
  @documents_lock = Mutex.new

  def on_init(capabilites : LSProtocol::ClientCapabilities) : LSProtocol::ServerCapabilities?
  end

  def when_ready
  end

  def on_request(message)
    case message
    when LSProtocol::TextDocumentFormattingRequest
      @pending_requests << message.id
      params = message.params
      document_uri = URI.parse(params.text_document.uri)

      collection = @documents[document_uri]?
      return unless collection
      document, mutex = collection

      mutex.synchronize do
        GC.disable
        document.contents = Crystal.format(document.contents)
        GC.enable

        response = [
          LSProtocol::TextEdit.new(
            range: LSProtocol::Range.new(
              start: LSProtocol::Position.new(line: 0, character: 0),
              end: LSProtocol::Position.new(line: document.line_count + 1, character: 0_u32)
            ),
            new_text: document.contents
          ),
        ]

        return response
      end
    when LSProtocol::TextDocumentDocumentSymbolRequest
      params = message.params
      document_uri = URI.parse(params.text_document.uri)
      symbols = [] of LSProtocol::SymbolInformation

      collection = @documents[document_uri]?
      return symbols unless collection
      document, mutex = collection

      mutex.synchronize do
        GC.disable
        parser = Crystal::Parser.new(document.contents)
        parser.filename = document_uri.path
        parser.wants_doc = false

        visitor = DocumentSymbolsVisitor.new(params.text_document.uri)
        parser.parse.accept(visitor)

        symbols = visitor.symbols
        GC.enable
      end

      return symbols
    else
      Log.error { "Unhandled request message #{message.class.to_s.split("::").last}" }
    end

    nil
  ensure
    @pending_requests.delete(message.id)
  end

  def on_notification(message)
    case message
    when LSProtocol::TextDocumentDidOpenNotification
      params = message.params
      document_uri = URI.parse(params.text_document.uri)

      @documents[document_uri] = {
        TextDocument.new(
          document_uri,
          params.text_document.text
        ),
        Mutex.new,
      }
    when LSProtocol::TextDocumentDidCloseNotification
      params = message.params
      document_uri = URI.parse(params.text_document.uri)

      contents = @documents[document_uri]?
      return unless contents
      document, mutex = contents

      mutex.synchronize do
        @documents.delete(document_uri)
      end
    when LSProtocol::TextDocumentDidChangeNotification
      params = message.params
      document_uri = URI.parse(params.text_document.uri)
      changes = params.content_changes

      contents = @documents[document_uri]?
      return unless contents
      document, mutex = contents

      mutex.synchronize do
        document.update_contents(changes)
      end
    when LSProtocol::TextDocumentDidSaveNotification
    when LSProtocol::WorkspaceDidChangeWatchedFilesNotification
    else
      Log.error { "Unhandled notification message #{message.class.to_s.split("::").last}" }
    end

    nil
  end

  def on_response(message)
    case message
    when Nil
    else
      Log.error { "Unhandled response message #{message.class.to_s.split("::").last}" }
    end

    nil
  end
end
