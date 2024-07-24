require "../spec_helper"

describe Larimar::Workspace do
  context ".find_closest_shard_yml" do
    it "finds nearest shard.yml" do
      result = Larimar::Workspace.find_closest_shard_yml(
        Path.new(__FILE__).to_uri
      )
      result.should_not be_nil

      next if result.nil?

      Path.new(result.path).basename.should eq("larimar")
    end

    it "returns nil if there's no shard.yml" do
      result = Larimar::Workspace.find_closest_shard_yml(
        Path.new(__DIR__, "..", "..", "..", "..").normalize.to_uri
      )
      result.should be_nil
    end

    it "doesn't find shard.yml in lib folder" do
      result = Larimar::Workspace.find_closest_shard_yml(
        Path.new(__DIR__, "..", "..", "lib", "lsprotocol", "src").normalize.to_uri
      )
      result.should_not be_nil

      next if result.nil?

      Path.new(result.path).basename.should eq("larimar")
    end
  end
end
