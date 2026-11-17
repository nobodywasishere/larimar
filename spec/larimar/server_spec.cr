require "../spec_helper"

private MESSAGE = %({"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///spec_subject.cr"}}})

private def recv_msg(headers : String)
  input = IO::Memory.new("#{headers}\r\n#{MESSAGE}")
  Larimar::Server.new(input, IO::Memory.new).recv_msg
end

describe Larimar::Server do
  describe "#recv_msg" do
    it "reads a message with a single header" do
      recv_msg("Content-Length: #{MESSAGE.bytesize}\r\n")
        .should be_a(LSProtocol::DidCloseTextDocumentNotification)
    end

    it "reads a message with both headers" do
      recv_msg(
        "Content-Length: #{MESSAGE.bytesize}\r\n" \
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
      ).should be_a(LSProtocol::DidCloseTextDocumentNotification)
    end

    it "reads a message with the headers in any order and case" do
      recv_msg(
        "content-type: application/vscode-jsonrpc; charset=utf-8\r\n" \
        "content-length: #{MESSAGE.bytesize}\r\n"
      ).should be_a(LSProtocol::DidCloseTextDocumentNotification)
    end

    it "ignores unknown headers" do
      recv_msg(
        "X-Custom: foo:bar\r\n" \
        "Content-Length: #{MESSAGE.bytesize}\r\n"
      ).should be_a(LSProtocol::DidCloseTextDocumentNotification)
    end

    it "reads consecutive messages" do
      frame = "Content-Length: #{MESSAGE.bytesize}\r\n" \
              "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" \
              "\r\n#{MESSAGE}"
      server = Larimar::Server.new(IO::Memory.new(frame * 2), IO::Memory.new)

      2.times do
        server.recv_msg.should be_a(LSProtocol::DidCloseTextDocumentNotification)
      end
    end
  end
end
