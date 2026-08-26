defmodule IexCode.Research.HTMLReport do
  @moduledoc """
  Renders research Markdown as a self-contained, inert HTML report.

  Report text is untrusted. It is escaped before the small supported Markdown
  vocabulary is applied, and no script, stylesheet link, image, iframe, or
  inline event handler is emitted. HTTP(S) citation anchors are the only
  external references permitted in the output.
  """

  @max_markdown_bytes 2_000_000
  @max_title_bytes 500

  @spec render(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(markdown, opts \\ [])

  def render(markdown, opts) when is_binary(markdown) and is_list(opts) do
    cond do
      not String.valid?(markdown) ->
        {:error, :invalid_utf8}

      byte_size(markdown) > @max_markdown_bytes ->
        {:error, {:markdown_too_large, @max_markdown_bytes}}

      true ->
        title =
          bounded_text(Keyword.get(opts, :title) || first_heading(markdown) || "Research report")

        subtitle = bounded_text(Keyword.get(opts, :subtitle) || "Evidence brief")
        generated_at = generated_at(Keyword.get(opts, :generated_at))
        source_count = nonnegative_integer(Keyword.get(opts, :source_count), 0)
        body = render_blocks(markdown)

        {:ok, document(title, subtitle, generated_at, source_count, body)}
    end
  end

  def render(_markdown, _opts), do: {:error, :invalid_report}

  defp document(title, subtitle, generated_at, source_count, body) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'">
        <meta name="referrer" content="no-referrer">
        <title>#{escape(title)}</title>
        <style>
          :root{color-scheme:dark;--ink:#ece7dd;--muted:#9d988f;--faint:#67645f;--line:#2d3138;--panel:#11151a;--panel2:#161b21;--bg:#090c10;--coral:#ef8b6b;--cyan:#69c8d4;--mint:#74d3a5;--warn:#efbd68}
          *{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--ink);font-family:Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.7}
          body:before{content:"";position:fixed;inset:0;pointer-events:none;background:linear-gradient(rgba(255,255,255,.018) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.014) 1px,transparent 1px);background-size:36px 36px;mask-image:linear-gradient(to bottom,#000,transparent 70%)}
          .shell{width:min(1180px,calc(100% - 32px));margin:0 auto}.hero{padding:72px 0 42px;border-bottom:1px solid var(--line)}
          .eyebrow,.meta,.section-no{font:600 11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;text-transform:uppercase;letter-spacing:.16em}.eyebrow{color:var(--coral)}
          h1{max-width:950px;margin:14px 0 12px;font-size:clamp(38px,7vw,84px);line-height:.98;letter-spacing:-.055em} .lede{max-width:720px;margin:0;color:var(--muted);font-size:18px}
          .facts{display:flex;flex-wrap:wrap;gap:1px;margin-top:30px;background:var(--line);border:1px solid var(--line)}.fact{min-width:180px;flex:1;background:var(--panel);padding:13px 16px}.fact b{display:block;color:var(--ink);font-size:13px}.fact span{color:var(--faint);font-size:10px;text-transform:uppercase;letter-spacing:.12em}
          main{padding:48px 0 90px}.report{display:grid;grid-template-columns:minmax(0,1fr);gap:0}.report>h2{margin:70px 0 22px;padding-top:22px;border-top:1px solid var(--line);font-size:clamp(26px,4vw,43px);line-height:1.08;letter-spacing:-.035em}.report>h2:first-child{margin-top:0}.report>h3{margin:42px 0 14px;font-size:23px;line-height:1.2}.report>h4{margin:30px 0 10px;color:var(--cyan);font-size:14px;text-transform:uppercase;letter-spacing:.08em}
          p{max-width:82ch;margin:0 0 18px;color:#cbc7bf}strong{color:#fff}code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.inline-code{padding:2px 6px;border:1px solid var(--line);background:var(--panel2);color:var(--cyan);font-size:.9em}
          a{color:var(--cyan);text-decoration-thickness:1px;text-underline-offset:3px}a:hover{color:#9be2ea}.anchor{color:inherit;text-decoration:none}.anchor:hover{color:var(--coral)}
          ul,ol{max-width:82ch;margin:0 0 24px;padding-left:24px}li{margin:7px 0;color:#cbc7bf}li::marker{color:var(--coral)}blockquote{max-width:82ch;margin:26px 0;padding:18px 22px;border-left:3px solid var(--coral);background:var(--panel);color:#d9d5cd}
          pre{max-width:100%;overflow:auto;margin:24px 0;padding:18px;border:1px solid var(--line);background:#070a0d;color:#c7dce0;font:12px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace}hr{border:0;border-top:1px solid var(--line);margin:42px 0}
          .table-wrap{max-width:100%;overflow:auto;margin:24px 0;border:1px solid var(--line)}table{width:100%;border-collapse:collapse;background:var(--panel);font-size:13px}th,td{padding:12px 14px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{position:sticky;top:0;background:var(--panel2);color:#fff;font:600 10px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;text-transform:uppercase;letter-spacing:.1em}tr:last-child td{border-bottom:0}
          footer{padding:22px 0 44px;border-top:1px solid var(--line);color:var(--faint);font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
          @media(max-width:640px){.shell{width:min(100% - 22px,1180px)}.hero{padding-top:45px}.facts{display:grid;grid-template-columns:1fr 1fr}.fact{min-width:0}.report>h2{margin-top:50px}th,td{min-width:150px}}
          @media print{:root{color-scheme:light;--ink:#111;--muted:#444;--faint:#666;--line:#ccc;--panel:#fff;--panel2:#f5f5f3;--bg:#fff;--coral:#9d3e25;--cyan:#176775}body:before{display:none}.hero{padding-top:24px}a{color:#176775}pre{white-space:pre-wrap}.report>h2{break-after:avoid}table,blockquote,pre{break-inside:avoid}}
        </style>
      </head>
      <body>
        <header class="hero"><div class="shell"><div class="eyebrow">IexCode · durable research artifact</div><h1>#{escape(title)}</h1><p class="lede">#{escape(subtitle)}</p><div class="facts"><div class="fact"><span>Generated</span><b>#{escape(generated_at)}</b></div><div class="fact"><span>Evidence sources</span><b>#{source_count}</b></div><div class="fact"><span>Format</span><b>Self-contained HTML</b></div></div></div></header>
        <main class="shell"><article class="report">#{body}</article></main>
        <footer><div class="shell">Static report · no scripts, remote styles, fonts, frames, or images.</div></footer>
      </body>
    </html>
    """
  end

  defp render_blocks(markdown) do
    markdown
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> consume([], nil, false, [], [])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp consume([], paragraph, list, true, code, output) do
    output
    |> flush_paragraph(paragraph)
    |> flush_list(list)
    |> prepend_code(code)
  end

  defp consume([], paragraph, list, false, _code, output) do
    output |> flush_paragraph(paragraph) |> flush_list(list)
  end

  defp consume([line | rest], paragraph, list, true, code, output) do
    if String.starts_with?(String.trim_leading(line), "```") do
      output = output |> flush_paragraph(paragraph) |> flush_list(list) |> prepend_code(code)
      consume(rest, [], nil, false, [], output)
    else
      consume(rest, paragraph, list, true, [line | code], output)
    end
  end

  defp consume([line | rest] = lines, paragraph, list, false, _code, output) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        consume(
          rest,
          [],
          nil,
          false,
          [],
          output |> flush_paragraph(paragraph) |> flush_list(list)
        )

      String.starts_with?(trimmed, "```") ->
        consume(rest, [], nil, true, [], output |> flush_paragraph(paragraph) |> flush_list(list))

      table_start?(lines) ->
        {table_lines, remaining} = take_table(lines)
        output = output |> flush_paragraph(paragraph) |> flush_list(list)
        consume(remaining, [], nil, false, [], [render_table(table_lines) | output])

      heading = heading(trimmed) ->
        {level, text} = heading
        output = output |> flush_paragraph(paragraph) |> flush_list(list)
        consume(rest, [], nil, false, [], [render_heading(level, text) | output])

      trimmed in ["---", "***", "___"] ->
        output = output |> flush_paragraph(paragraph) |> flush_list(list)
        consume(rest, [], nil, false, [], ["<hr>" | output])

      item = list_item(trimmed) ->
        {type, text} = item
        output = flush_paragraph(output, paragraph)

        if is_nil(list) or elem(list, 0) == type do
          {_, items} = list || {type, []}
          consume(rest, [], {type, [text | items]}, false, [], output)
        else
          output = flush_list(output, list)
          consume(rest, [], {type, [text]}, false, [], output)
        end

      String.starts_with?(trimmed, "> ") ->
        output = output |> flush_paragraph(paragraph) |> flush_list(list)
        quote = trimmed |> String.trim_leading("> ") |> inline()
        consume(rest, [], nil, false, [], ["<blockquote>#{quote}</blockquote>" | output])

      true ->
        output = flush_list(output, list)
        consume(rest, [trimmed | paragraph], nil, false, [], output)
    end
  end

  defp flush_paragraph(output, []), do: output

  defp flush_paragraph(output, lines),
    do: ["<p>#{lines |> Enum.reverse() |> Enum.join(" ") |> inline()}</p>" | output]

  defp flush_list(output, nil), do: output

  defp flush_list(output, {type, items}) do
    tag = if type == :ordered, do: "ol", else: "ul"
    body = items |> Enum.reverse() |> Enum.map_join(&"<li>#{inline(&1)}</li>")
    ["<#{tag}>#{body}</#{tag}>" | output]
  end

  defp prepend_code(output, code),
    do: ["<pre><code>#{escape(Enum.join(Enum.reverse(code), "\n"))}</code></pre>" | output]

  defp heading(line) do
    case Regex.run(~r/^(\#{1,4})\s+(.+)$/u, line, capture: :all_but_first) do
      [marks, text] -> {String.length(marks), text}
      _ -> nil
    end
  end

  defp render_heading(1, text), do: "<h2>#{inline(text)}</h2>"
  defp render_heading(level, text), do: "<h#{min(level, 4)}>#{inline(text)}</h#{min(level, 4)}>"

  defp list_item(line) do
    case Regex.run(~r/^[-*+]\s+(.+)$/u, line, capture: :all_but_first) do
      [text] -> {:unordered, text}
      _ -> ordered_item(line)
    end
  end

  defp ordered_item(line) do
    case Regex.run(~r/^\d+[.)]\s+(.+)$/u, line, capture: :all_but_first) do
      [text] -> {:ordered, text}
      _ -> nil
    end
  end

  defp table_start?([header, separator | _rest]) do
    String.contains?(header, "|") and Regex.match?(~r/^\s*\|?\s*:?-{3,}/u, separator)
  end

  defp table_start?(_lines), do: false

  defp take_table([header, _separator | rest]) do
    {rows, remaining} = Enum.split_while(rest, &String.contains?(&1, "|"))
    {[header | rows], remaining}
  end

  defp render_table([header | rows]) do
    head = header |> table_cells() |> Enum.map_join(&"<th>#{inline(&1)}</th>")

    body =
      Enum.map_join(rows, fn row ->
        cells = row |> table_cells() |> Enum.map_join(&"<td>#{inline(&1)}</td>")
        "<tr>#{cells}</tr>"
      end)

    "<div class=\"table-wrap\"><table><thead><tr>#{head}</tr></thead><tbody>#{body}</tbody></table></div>"
  end

  defp table_cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp inline(text), do: inline(text, []) |> Enum.reverse() |> IO.iodata_to_binary()

  defp inline("", output), do: output

  defp inline(text, output) do
    case Regex.run(~r/(`[^`\n]+`|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\((?:<[^>\n]+>|[^\s)]+)\))/u, text,
           return: :index,
           capture: :first
         ) do
      [{start, length}] ->
        prefix = binary_part(text, 0, start)
        token = binary_part(text, start, length)
        rest = binary_part(text, start + length, byte_size(text) - start - length)
        inline(rest, [render_inline_token(token), escape(prefix) | output])

      nil ->
        [escape(text) | output]
    end
  end

  defp render_inline_token("`" <> token),
    do: "<code class=\"inline-code\">#{token |> String.trim_trailing("`") |> escape()}</code>"

  defp render_inline_token("**" <> token),
    do: "<strong>#{token |> String.trim_trailing("**") |> escape()}</strong>"

  defp render_inline_token(token) do
    case Regex.run(~r/^\[([^\]]+)\]\(([^)]+)\)$/u, token, capture: :all_but_first) do
      [label, url] -> render_link(label, unwrap_destination(url))
      _ -> escape(token)
    end
  end

  defp unwrap_destination("<" <> url), do: String.trim_trailing(url, ">")
  defp unwrap_destination(url), do: url

  defp render_link(label, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        "<a href=\"#{escape(url)}\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">#{escape(label)}</a>"

      _ ->
        escape(label)
    end
  end

  defp first_heading(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^#\s+(.+)$/u, String.trim(line), capture: :all_but_first) do
        [heading] -> heading
        _ -> nil
      end
    end)
  end

  defp bounded_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, @max_title_bytes)
    |> case do
      "" -> "Research report"
      text -> text
    end
  end

  defp bounded_text(_value), do: "Research report"

  defp generated_at(%DateTime{} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp generated_at(%NaiveDateTime{} = value),
    do: value |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

  defp generated_at(value) when is_binary(value), do: String.slice(value, 0, 80)

  defp generated_at(_value),
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value, default), do: default

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
