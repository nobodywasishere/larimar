require "../larimar"

server = Larimar::Server.new(STDIN, STDOUT)

backend = Larimar::LogBackend.new(server, formatter: Larimar::LogFormatter)
::Log.setup_from_env(backend: backend)

controller = Larimar::ProviderController.new
controller.register_provider(Larimar::CrystalProvider.new)
controller.register_provider(Larimar::TreeSitterProvider.new)

server.start(controller)
