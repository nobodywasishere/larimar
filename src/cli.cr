require "./larimar"

::Log.setup_from_env

server = Larimar::Server.new(STDIN, STDOUT)
controller = Larimar::Controller.new

server.start(controller)
