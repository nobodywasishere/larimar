require "./spec_helper"

class DummyController < Larimar::Controller
  def initialize
  end

  def on_init(capabilites)
  end

  def when_ready
  end

  def on_request(message)
  end

  def on_notification(message)
  end

  def on_response(message)
  end
end

def write_message(io : IO, string : String)
  io << "Content-Length:#{string.to_slice.size}\r\n\r\n"
  io << string
  Fiber.yield
end

def read_message(io : IO)
  Fiber.yield
  length = io.read_line[15..].to_i
  io.read_line
  io.read_string(length)
end

describe Larimar::Server do
  it "works" do
    input = IO::Stapled.new(*IO.pipe)
    output = IO::Stapled.new(*IO.pipe)
    server = Larimar::Server.new(input, output, LSProtocol::ServerCapabilities.new(
      text_document_sync: LSProtocol::TextDocumentSyncKind::Incremental
    ))
    # ::Log.setup(:debug, ::Log::IOBackend.new(STDOUT))

    spawn do
      server.start(DummyController.new)
    end
    Fiber.yield

    write_message(input, %({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"processId":62731,"clientInfo":{"name":"vscode","version":"1.50.1"},"rootPath":"/Users/elbywan/Programmation/crystal-experiments/test-compiler","rootUri":"file:///Users/elbywan/Programmation/crystal-experiments/test-compiler","capabilities":{"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true,"resourceOperations":["create","rename","delete"],"failureHandling":"textOnlyTransactional"},"didChangeConfiguration":{"dynamicRegistration":true},"didChangeWatchedFiles":{"dynamicRegistration":true},"symbol":{"dynamicRegistration":true,"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]}},"executeCommand":{"dynamicRegistration":true},"configuration":true,"workspaceFolders":true},"textDocument":{"publishDiagnostics":{"relatedInformation":true,"versionSupport":false,"tagSupport":{"valueSet":[1,2]}},"synchronization":{"dynamicRegistration":true,"willSave":true,"willSaveWaitUntil":true,"didSave":true},"completion":{"dynamicRegistration":true,"contextSupport":true,"completionItem":{"snippetSupport":true,"commitCharactersSupport":true,"documentationFormat":["markdown","plaintext"],"deprecatedSupport":true,"preselectSupport":true,"tagSupport":{"valueSet":[1]}},"completionItemKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]}},"hover":{"dynamicRegistration":true,"contentFormat":["markdown","plaintext"]},"signatureHelp":{"dynamicRegistration":true,"signatureInformation":{"documentationFormat":["markdown","plaintext"],"parameterInformation":{"labelOffsetSupport":true}},"contextSupport":true},"definition":{"dynamicRegistration":true,"linkSupport":true},"references":{"dynamicRegistration":true},"documentHighlight":{"dynamicRegistration":true},"documentSymbol":{"dynamicRegistration":true,"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},"hierarchicalDocumentSymbolSupport":true},"codeAction":{"dynamicRegistration":true,"isPreferredSupport":true,"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["","quickfix","refactor","refactor.extract","refactor.inline","refactor.rewrite","source","source.organizeImports"]}}},"codeLens":{"dynamicRegistration":true},"formatting":{"dynamicRegistration":true},"rangeFormatting":{"dynamicRegistration":true},"onTypeFormatting":{"dynamicRegistration":true},"rename":{"dynamicRegistration":true,"prepareSupport":true},"documentLink":{"dynamicRegistration":true,"tooltipSupport":true},"typeDefinition":{"dynamicRegistration":true,"linkSupport":true},"implementation":{"dynamicRegistration":true,"linkSupport":true},"colorProvider":{"dynamicRegistration":true},"foldingRange":{"dynamicRegistration":true,"rangeLimit":5000,"lineFoldingOnly":true},"declaration":{"dynamicRegistration":true,"linkSupport":true},"selectionRange":{"dynamicRegistration":true}},"window":{"workDoneProgress":true}},"trace":"off","workspaceFolders":[{"uri":"file:///Users/elbywan/Programmation/crystal-experiments/test-compiler","name":"test-compiler"}]}}))
    read_message(output).should eq %({"id":0,"result":{"capabilities":{"textDocumentSync":2}},"jsonrpc":"2.0"})
    write_message(input, %({"jsonrpc":"2.0","id":1,"method":"initialized","params":{}}))
    read_message(output).should eq %({"jsonrpc":"2.0","id":1,"result":null})
    write_message(input, %({"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}))
    read_message(output).should eq %({"jsonrpc":"2.0","id":2,"result":null})
  end
end
