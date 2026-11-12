require "./spec_helper"

describe CancellationToken do
  describe "#cancelled?" do
    it "returns false before the source gets cancelled" do
      source = CancellationTokenSource.new
      source.token.cancelled?.should be_false
    end

    it "returns true once the source gets cancelled" do
      source = CancellationTokenSource.new
      source.cancel
      source.token.cancelled?.should be_true
    end
  end

  describe "#cancelled!" do
    it "doesn't raise before the source gets cancelled" do
      source = CancellationTokenSource.new
      source.token.cancelled!
    end

    it "raises once the source gets cancelled" do
      source = CancellationTokenSource.new
      source.cancel

      expect_raises(CancellationException) do
        source.token.cancelled!
      end
    end
  end
end
