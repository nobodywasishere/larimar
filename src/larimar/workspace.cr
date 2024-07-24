class Larimar::Workspace
  def self.get_project_root(uri : URI) : Workspace
    result = find_closest_shard_yml(uri)

    if result
      new(
        name: Path[result.path].basename,
        uri: result
      )
    else
      new(
        name: Path[result.path].parent.basename,
        uri: Path[result.path].parent.to_uri
      )
    end
  end

  def self.find_closest_shard_yml(uri : URI) : URI?
    # Check if it's a project root folder
    if File.exists?(Path.new(uri.path, "shard.yml"))
      return uri
    end

    curr_dir = Path.new(uri.path).parent
    while curr_dir != curr_dir.root
      shard_yml = Path.new(curr_dir, "shard.yml")
      lib_dir = Path.new(curr_dir, "..", "..", "lib").normalize

      if File.exists?(shard_yml) && !File.exists?(lib_dir)
        return curr_dir.to_uri
      end

      curr_dir = curr_dir.parent
    end

    nil
  end

  getter name : String
  getter uri : URI
  getter index : Int32?

  def initialize(@name, @uri, @index = nil)
  end
end
