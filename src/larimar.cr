require "log"
require "json"
require "uri"
require "lsprotocol"
require "ameba"
require "tree_sitter"
require "rwlock"

require "./cancellation_token"

require "./ext/visitor"

require "./parser/document"
require "./parser/lexer"
require "./parser/token_kind"
require "./parser/token"
require "./parser/ast"
require "./parser/parser"

require "./semantic/environment"
require "./semantic/semantic_context"
require "./semantic/semantic_visitor"

require "./larimar/log"
require "./larimar/text_document"
require "./larimar/workspace"
# require "./larimar/compiler"
require "./larimar/server"
require "./larimar/controller"
# require "./larimar/controllers/crystal_controller"
# require "./larimar/controllers/parser_controller"
require "./larimar/controllers/provider_controller"

require "./providers"
require "./providers/*"

require "./tree_sitter_converter"

# require "./larimar/analysis/document_symbols_visitor"
# require "./larimar/analysis/semantic_tokens_visitor"

module Larimar
  VERSION = "0.1.0"

  Log = ::Log.for(self)
end
