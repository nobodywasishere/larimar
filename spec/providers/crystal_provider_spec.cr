require "../spec_helper"

private def inlay_hints(source)
  document = Larimar::TextDocument.new(source, URI.parse("file:///nonexistent/spec_subject.cr"), 1)
  range = LSProtocol::Range.new(
    start: LSProtocol::Position.new(line: 0, character: 0),
    end: LSProtocol::Position.new(line: 100, character: 0)
  )
  Larimar::CrystalProvider.new
    .provide_inlay_hints(document, range, nil)
    .try(&.map { |hint| {hint.position.line, hint.position.character} })
end

describe Larimar::CrystalProvider do
  describe "#provide_inlay_hints" do
    it "hints local variables assigned before being referenced" do
      inlay_hints("def foo\n  a = 1\n  b, c = 2, 3\n  a + b + c\nend\n")
        .should eq([{1_u32, 3_u32}, {2_u32, 3_u32}, {2_u32, 6_u32}])
    end

    it "doesn't hint variables first assigned using an op assign" do
      inlay_hints("def foo(a)\n  a += 1\n  a\nend\n").should eq([] of {UInt32, UInt32})
    end
  end
end
