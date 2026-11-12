require "file_utils"
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

    it "finds shard.yml with an unrelated lib folder two levels up" do
      # Like a shard placed in `/workspaces/app`, with `/lib` existing on Linux
      root = Path.new(File.tempname("larimar-workspace"))
      app = root / "workspaces" / "app"

      Dir.mkdir_p(root / "lib")
      Dir.mkdir_p(app / "src")
      File.touch(app / "shard.yml")

      begin
        result = Larimar::Workspace.find_closest_shard_yml(
          (app / "src" / "app.cr").to_uri
        )
        result.should_not be_nil

        next if result.nil?

        Path.new(result.path).should eq(app)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
