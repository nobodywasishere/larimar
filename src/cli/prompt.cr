require "../larimar"
require "json"

loop do
  STDOUT.print "larimar> "
  document = Larimar::Parser::Document.new(STDIN.gets(chomp: false) || "")

  parser = Larimar::Parser.parse_full(document)

  if document.tokens.size > 0
    puts "Tokens:"
    puts "- " + document.tokens.map{|t| "#{t.length}: #{t.kind}"}.join("\n- ")
  end

  if document.lex_errors.size > 0
    puts "Lexer Errors:"
    puts "- " + document.lex_errors.map{|t| "#{t.pos}: #{t.message}"}.join("\n- ")
  end

  print `echo '#{document.ast.to_json}' | jq`

  if document.parse_errors.size > 0
    puts "Parser Errors:"
    puts "- " + document.parse_errors.map{|t| "#{t.pos}: #{t.message}"}.join("\n- ")
  end
rescue ex
  puts "Unhandled exception: #{ex} (#{typeof(ex)})\n  #{ex.backtrace.join("\n  ")}"
end
