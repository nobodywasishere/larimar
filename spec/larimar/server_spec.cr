require "../spec_helper"
require "log/spec"

private MESSAGE = %({"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///spec_subject.cr"}}})

private class IdleController < Larimar::Controller
  def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)
  end
end

private class RaisingController < Larimar::Controller
  def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)
  end

  def on_request(message : LSProtocol::HoverRequest, cancel_token : CancellationToken) : LSProtocol::Message?
    raise "Oops"
  end
end

private class FailingInitController < Larimar::Controller
  def on_init(init_params : LSProtocol::InitializeParams) : LSProtocol::InitializeResult
    raise "Oops"
  end
end

# Records the notifications and responses it handles.
private class RecordingController < IdleController
  getter handled = [] of LSProtocol::Message

  def on_notification(message : LSProtocol::DidCloseTextDocumentNotification) : Nil
    handled << message
  end

  def on_response(message : Larimar::ClientResponse) : Nil
    handled << message
  end
end

# Returns the JSON of the single message written to *output*.
private def single_reply(output : IO::Memory) : JSON::Any
  response = output.to_s
  response.scan("Content-Length").size.should eq(1)

  JSON.parse(response.partition("\r\n\r\n")[2])
end

private HOVER_REQUEST = %({"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.cr"},"position":{"line":0,"character":0}}})

# Dispatches the request *json* to *controller*, returning the error answering it.
private def dispatch_error(controller, json) : LSProtocol::ResponseError?
  output = IO::Memory.new
  server = Larimar::Server.new(IO::Memory.new, output)
  server.dispatch(controller, server.parse_msg(json))

  100.times do
    break unless output.empty?
    sleep 10.milliseconds
  end

  LSProtocol::ResponseErrorMessage.from_json(output.to_s.partition("\r\n\r\n")[2]).error
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

    it "reads a message with non-ASCII contents" do
      json = %({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.cr","languageId":"crystal","version":1,"text":"aé😀"}}})
      server = Larimar::Server.new(IO::Memory.new(frame(json) + frame(json)), IO::Memory.new)

      2.times do
        text = server.recv_msg.as(LSProtocol::DidOpenTextDocumentNotification).params.text_document.text
        text.should eq("aé😀")
        text.size.should eq(3)
      end
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

    it "keeps the method of a request until a response to it gets parsed" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)
      server.send_msg(LSProtocol.parse_message(
        %({"jsonrpc":"2.0","id":7,"method":"workspace/configuration","params":{"items":[]}})
      ))

      expect_raises(JSON::ParseException) do
        server.parse_msg(%({"jsonrpc":"2.0","id":7,"result":123}))
      end
      server.parse_msg(%({"jsonrpc":"2.0","id":7,"result":[{"foo":1}]}))
        .should be_a(LSProtocol::ConfigurationResponse)
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

    {
      {"invalid JSON", %({), LSProtocol::ErrorCodes::ParseError},
      {"a non-object", %([]), LSProtocol::ErrorCodes::InvalidRequest},
      {"no JSON-RPC version", %({"id":3,"method":"shutdown"}), LSProtocol::ErrorCodes::InvalidRequest},
      {"an invalid id", %({"jsonrpc":"2.0","id":1.5,"method":"shutdown"}), LSProtocol::ErrorCodes::InvalidRequest},
      {"neither a method, a result nor an error", %({"jsonrpc":"2.0","id":17}), LSProtocol::ErrorCodes::InvalidRequest},
    }.each do |name, json, code|
      it "raises for a message with #{name}, without an id" do
        server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

        error = expect_raises(Larimar::Server::MessageError) do
          server.parse_msg(json)
        end
        error.id.should be_nil
        error.code.should eq(code)
      end
    end

    it "raises for a notification with an id" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

      error = expect_raises(Larimar::Server::MessageError) do
        server.parse_msg(%({"jsonrpc":"2.0","id":18,"method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.cr"}}}))
      end
      error.id.should eq(18)
      error.code.should eq(LSProtocol::ErrorCodes::InvalidRequest)
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

  describe "#server_loop" do
    {
      {"invalid JSON", %({), LSProtocol::ErrorCodes::ParseError},
      {"no method, result nor error", %({"jsonrpc":"2.0","id":17}), LSProtocol::ErrorCodes::InvalidRequest},
    }.each do |name, json, code|
      it "answers a message with #{name} with an error with a null id, not handling it" do
        output = IO::Memory.new
        controller = RecordingController.new
        Larimar::Server.new(IO::Memory.new(frame(json)), output).server_loop(controller)
        Fiber.yield

        reply = single_reply(output)
        reply["id"].raw.should be_nil
        reply["error"]["code"].should eq(code.value)
        controller.handled.should be_empty
      end
    end

    it "answers a notification with an id with an error, not handling it" do
      output = IO::Memory.new
      controller = RecordingController.new
      json = %({"jsonrpc":"2.0","id":18,"method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.cr"}}})
      Larimar::Server.new(IO::Memory.new(frame(json)), output).server_loop(controller)
      Fiber.yield

      reply = single_reply(output)
      reply["id"].should eq(18)
      reply["error"]["code"].should eq(LSProtocol::ErrorCodes::InvalidRequest.value)
      controller.handled.should be_empty
    end

    it "doesn't answer a response without an id" do
      output = IO::Memory.new
      json = %({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"oops"}})
      Larimar::Server.new(IO::Memory.new(frame(json)), output).server_loop(RecordingController.new)

      output.empty?.should be_true
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

  describe "unhandled notifications" do
    it "get logged as debug ones if they may be ignored, as warnings otherwise" do
      set_trace = LSProtocol.parse_message(%({"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"off"}}))
      saved = LSProtocol.parse_message(%({"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"file:///a.cr"}}}))

      Log.capture(level: :debug) do |logs|
        IdleController.new.on_notification(set_trace.as(LSProtocol::Notification))
        IdleController.new.on_notification(saved.as(LSProtocol::Notification))

        logs.next(:debug, "Unhandled notification message SetTraceNotification")
        logs.next(:warn, "Unhandled notification message DidSaveTextDocumentNotification")
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

    it "answers an initialize request failing to be handled as an internal error" do
      json = %({"jsonrpc":"2.0","id":19,"method":"initialize","params":{"capabilities":{}}})
      output = IO::Memory.new

      Larimar::Server.new(IO::Memory.new(frame(json)), output).handshake(FailingInitController.new).should be_false

      reply = single_reply(output)
      reply["id"].should eq(19)
      reply["error"]["code"].should eq(LSProtocol::ErrorCodes::InternalError.value)
      reply["error"]["message"].should eq("Oops")
    end

    it "answers an initialize request with invalid params as such" do
      input = IO::Memory.new(frame(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"processId":"x"}})))
      output = IO::Memory.new

      Larimar::Server.new(input, output).handshake(IdleController.new).should be_false

      error = LSProtocol::ResponseErrorMessage.from_json(output.to_s.partition("\r\n\r\n")[2])
      error.id.should eq(0)
      error.error.try(&.code).should eq(LSProtocol::ErrorCodes::InvalidParams.value)
    end
  end

  describe "#dispatch" do
    it "answers a request no handler handles as an unknown method" do
      dispatch_error(IdleController.new, HOVER_REQUEST).try(&.code)
        .should eq(LSProtocol::ErrorCodes::MethodNotFound.value)
    end

    it "answers a request whose handler raises as an internal error" do
      error = dispatch_error(RaisingController.new, HOVER_REQUEST)
      error.try(&.code).should eq(LSProtocol::ErrorCodes::InternalError.value)
      error.try(&.message).should eq("Oops")
    end
  end
end
