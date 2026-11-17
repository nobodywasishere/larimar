require "../spec_helper"

private def frame(json : String) : String
  "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
end

private class NullController < Larimar::Controller
  def on_init(init_params) : LSProtocol::InitializeResult
    LSProtocol::InitializeResult.new(LSProtocol::ServerCapabilities.new)
  end

  def on_notification(message) : Nil
  end
end

private INITIALIZE = frame(%({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}))

# Runs the server over *input*, failing unless it returns in a timely manner.
private def start_server(input : String)
  server = Larimar::Server.new(IO::Memory.new(input), IO::Memory.new)
  done = Channel(Nil).new(1)

  spawn do
    server.start(NullController.new)
    done.send(nil)
  end

  select
  when done.receive
  when timeout(1.second)
    fail "Server didn't return after the input got closed"
  end
end

describe Larimar::Server do
  describe "#recv_msg" do
    it "raises IO::EOFError once the input is closed" do
      server = Larimar::Server.new(IO::Memory.new, IO::Memory.new)

      expect_raises(IO::EOFError) { server.recv_msg }
    end

    it "raises IO::EOFError if the input is closed within a message" do
      server = Larimar::Server.new(IO::Memory.new("Content-Length: 100\r\n\r\n{}"), IO::Memory.new)

      expect_raises(IO::EOFError) { server.recv_msg }
    end
  end

  describe "#start" do
    it "returns if the input is closed before initialization" do
      start_server("")
    end

    it "returns if the input is closed after initialization" do
      start_server(INITIALIZE)
    end

    it "survives a malformed message" do
      start_server(INITIALIZE + frame("{not json"))
    end
  end
end
