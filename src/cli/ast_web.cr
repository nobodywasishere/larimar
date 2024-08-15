require "http/server"
require "../larimar"

html = <<-HTML
<!DOCTYPE html>

<html lang="en-US">
<head>
  <script defer src="https://unpkg.com/htmx.org@1.9.4/dist/htmx.min.js"></script>
</head>
<body>
  <table>
    <tr style="vertical-align: top;">
      <td>
        <textarea name="src" placeholder="Parse Crystal..." rows=40 cols=40
          autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
          hx-post="/parse" hx-trigger="keyup changed" hx-target="#parse-results"></textarea>
      </td>
      <td>
        <div id="parse-results"></div>
      </td>
    </tr>
  </table>
</body>
HTML

server = HTTP::Server.new do |context|
  request = context.request

  case {request.method, request.path}
  when {"GET", "/"}, {"GET", "/index.html"}
    puts "#{request.method} #{request.path}: sending /index.html"

    context.response.content_type = "text/html; charset=utf-8"
    context.response.print html
  when {"POST", "/parse"}
    src = request.form_params["src"]

    document = Larimar::Parser::Document.new(src)
    elapsed_time = Time.measure do
      Larimar::Parser.parse_full(document)
    end

    result = String.build do |str|
      str << "<p>" << elapsed_time << "</p>"

      if document.lex_errors.size > 0
        str << "<h4>Lexer Errors:</h4>"

        str << "<ul>"
        document.lex_errors.each do |le|
          str << "<li>#{le.pos}: #{le.message}</li>"
        end
        str << "</ul>"
      end

      if document.parse_errors.size > 0
        str << "<h4>Parser Errors:</h4>"

        str << "<ul>"
        document.parse_errors.each do |le|
          str << "<li>#{le.pos}: #{le.message}</li>"
        end
        str << "</ul>"
      end

      str << "<pre><code>\n"
      str << `echo '#{document.ast.to_json}' | jq`
      str << "\n</code></pre>"
    end

    context.response.content_type = "text/html; charset=utf-8"
    context.response.print result
  else
    puts "#{request.method} #{request.path}: unhandled"
  end
rescue ex
  result = String.build do |str|
    str << "<pre><code>\n"
    str << ex << "\n  "
    ex.backtrace.each do |bt|
      str << bt << "\n  "
    end
    str << "\n</code></pre>"
  end

  context.response.content_type = "text/html; charset=utf-8"
  context.response.print result
end

address = server.bind_tcp(8080)
puts "Listening on http://#{address}"

# This call blocks until the process is terminated
server.listen
