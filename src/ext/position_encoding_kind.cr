enum LSProtocol::PositionEncodingKind
  # Returns the number of code units *char* takes in this encoding.
  def code_units(char : Char) : Int32
    case self
    in .utf8?  then char.bytesize
    in .utf16? then char.ord >= 0x10000 ? 2 : 1
    in .utf32? then 1
    end
  end
end
