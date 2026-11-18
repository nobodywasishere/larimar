require "../spec_helper"
require "log/spec"

private MESSAGE = %({"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///spec_subject.cr"}}})

private class IdleController < Larimar::Controller
  def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)
  end
end

private def frame(json : String) : String
  "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
end

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

  describe "#parse_msg" do
    it "parses a response to a request sent to the client as the one of its method" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)
      server.send_msg(LSProtocol.parse_message(
        %({"jsonrpc":"2.0","id":7,"method":"workspace/configuration","params":{"items":[]}})
      ))

      response = server.parse_msg(%({"jsonrpc":"2.0","id":7,"result":[{"foo":1}]}))
      response.should be_a(LSProtocol::ConfigurationResponse)

      # The method gets forgotten once answered
      server.parse_msg(%({"jsonrpc":"2.0","id":7,"result":[{"foo":1}]}))
        .should be_a(LSProtocol::ResponseMessage)
    end

    it "forgets the methods of the oldest requests not answered" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

      (Larimar::Server::OUTGOING_METHODS_LIMIT + 1).times do |id|
        server.send_msg(LSProtocol.parse_message(
          %({"jsonrpc":"2.0","id":#{id},"method":"workspace/configuration","params":{"items":[]}})
        ))
      end

      server.parse_msg(%({"jsonrpc":"2.0","id":0,"result":[]}))
        .should be_a(LSProtocol::ResponseMessage)
      server.parse_msg(%({"jsonrpc":"2.0","id":1,"result":[]}))
        .should be_a(LSProtocol::ConfigurationResponse)
    end

    it "parses a response to an unknown request" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

      server.parse_msg(%({"jsonrpc":"2.0","id":1,"result":null}))
        .should be_a(LSProtocol::ResponseMessage)
      server.parse_msg(%({"jsonrpc":"2.0","id":"a","result":{"foo":1}}))
        .should be_a(LSProtocol::ResponseMessage)
    end

    {
      {"an unknown method", %({"jsonrpc":"2.0","id":3,"method":"foo/bar","params":{}}), LSProtocol::ErrorCodes::MethodNotFound},
      {"a non-string method", %({"jsonrpc":"2.0","id":3,"method":1}), LSProtocol::ErrorCodes::InvalidRequest},
      {"invalid params", %({"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"foo":1}}), LSProtocol::ErrorCodes::InvalidParams},
    }.each do |name, json, code|
      it "raises for a request with #{name}" do
        server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

        error = expect_raises(Larimar::Server::MessageError) do
          server.parse_msg(json)
        end
        error.id.should eq(3)
        error.code.should eq(code)
      end
    end

    it "raises for a notification with an unknown method, without an id" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

      error = expect_raises(Larimar::Server::MessageError) do
        server.parse_msg(%({"jsonrpc":"2.0","method":"$/foo"}))
      end
      error.id.should be_nil
      error.code.should eq(LSProtocol::ErrorCodes::MethodNotFound)
    end

    it "parses an error response" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

      server.parse_msg(%({"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"oops"}}))
        .should be_a(LSProtocol::ResponseErrorMessage)
    end
  end

  describe "#server_loop" do
    it "answers a request for an unknown method with an error" do
      input = IO::Memory.new(
        frame(%({"jsonrpc":"2.0","id":5,"method":"foo/bar","params":{}})) +
        frame(%({"jsonrpc":"2.0","method":"$/foo"}))
      )
      output = IO::Memory.new
      Larimar::Server.new(input, output).server_loop(IdleController.new)

      response = output.to_s
      response.scan("Content-Length").size.should eq(1)

      error = LSProtocol::ResponseErrorMessage.from_json(response.partition("\r\n\r\n")[2])
      error.id.should eq(5)
      error.error.try(&.code).should eq(LSProtocol::ErrorCodes::MethodNotFound.value)
    end
  end

  describe "#server_loop logging" do
    it "logs the errors of the notifications which may be ignored as debug ones" do
      input = IO::Memory.new(
        frame(%({"jsonrpc":"2.0","method":"$/foo"})) +
        frame(%({"jsonrpc":"2.0","method":"foo/bar"}))
      )

      Log.capture(level: :debug) do |logs|
        Larimar::Server.new(input, IO::Memory.new).server_loop(IdleController.new)

        logs.next(:debug, "Unknown method $/foo")
        logs.next(:warn, "Unknown method foo/bar")
      end
    end
  end

  describe "#handshake" do
    it "answers any request before the initialize one as not initialized" do
      input = IO::Memory.new(frame(%({"jsonrpc":"2.0","id":5,"method":"foo/bar","params":{}})))
      output = IO::Memory.new

      Larimar::Server.new(input, output).handshake(IdleController.new).should be_false

      error = LSProtocol::ResponseErrorMessage.from_json(output.to_s.partition("\r\n\r\n")[2])
      error.id.should eq(5)
      error.error.try(&.code).should eq(LSProtocol::ErrorCodes::ServerNotInitialized.value)
    end
  end
end
