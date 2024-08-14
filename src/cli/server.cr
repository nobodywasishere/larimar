require "../larimar"

server = Larimar::Server.new(STDIN, STDOUT)

backend = Larimar::LogBackend.new(server, formatter: Larimar::LogFormatter)
::Log.setup_from_env(backend: backend)

# controller = Larimar::CrystalController.new
controller = Larimar::Parser::Controller.new

server.start(controller)
