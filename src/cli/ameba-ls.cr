require "log"
require "json"
require "uri"
require "lsprotocol"
require "ameba"
require "tree_sitter"
require "rwlock"

require "../cancellation_token"

require "../ext/visitor"

require "../larimar/log"
require "../larimar/text_document"
require "../larimar/workspace"
require "../larimar/server"
require "../larimar/controller"

require "../providers"
require "../providers/ameba_provider"

module Larimar
  VERSION = "0.1.0"

  Log = ::Log.for(self)
end

server = Larimar::Server.new(STDIN, STDOUT)

backend = Larimar::LogBackend.new(server, formatter: Larimar::LogFormatter)
::Log.setup_from_env(backend: backend)

controller = Larimar::ProviderController.new
controller.register_provider(AmebaProvider.new)

server.start(controller)
