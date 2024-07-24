require "log"
require "json"
require "uri"
require "lsprotocol"

require "./larimar/log"
require "./larimar/workspace"
require "./larimar/server"
require "./larimar/controller"

module Larimar
  VERSION = "0.1.0"

  Log = ::Log.for(self)
end
