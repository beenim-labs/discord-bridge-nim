## Matrix <-> Discord conversion with formatter-based text parity helpers.

import std/json
import msgconv/formatter

type
  ConvertedMessage* = object
    body*: string
    raw*: JsonNode

proc convertMatrixToDiscord*(content: JsonNode): ConvertedMessage =
  var ctx = PillConvertContext()
  let parsed = parseMatrixHTML(
    MatrixHtmlMessage(
      body: content{"body"}.getStr(""),
      format: content{"format"}.getStr(""),
      formattedBody: content{"formatted_body"}.getStr(""),
      mentionedUserIds: @[]
    ),
    @[],
    ctx
  )
  ConvertedMessage(body: parsed.text, raw: content)

proc convertDiscordToMatrix*(content: JsonNode): ConvertedMessage =
  let rendered = renderDiscordMarkdownOnlyHTMLNoUnwrap(content{"content"}.getStr(""), allowInlineLinks = true)
  ConvertedMessage(body: rendered, raw: content)
