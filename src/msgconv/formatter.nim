## Matrix/Discord markdown formatting helpers.

import std/[strutils]
import msgconv/[formatter_everyone, formatter_tag]

type
  IndentableParagraphParser* = object

  MessageAllowedMentions* = object
    users*: seq[string]
    repliedUser*: bool

  MatrixHtmlMessage* = object
    body*: string
    format*: string
    formattedBody*: string
    mentionedUserIds*: seq[string]

  PillConvertContext* = object
    allowedMentions*: seq[string]
    inputAllowedMentions*: seq[string]
    resolveAliasRoom*: proc(alias: string): string {.closure.}
    resolveRoomMention*: proc(roomId, eventId: string): string {.closure.}
    resolveUserMention*: proc(mxid: string): string {.closure.}

const
  MatrixHtmlFormat* = "org.matrix.custom.html"

proc canAcceptIndentedLine*(b: IndentableParagraphParser): bool =
  discard b
  true

proc escapeReplacement*(s: string): string =
  if s.len < 2:
    return s
  s[0 .. 1] & r"\" & s[2 .. ^1]

proc appendIfNotContains*(arr: seq[string], newItem: string): seq[string] =
  for item in arr:
    if item == newItem:
      return arr
  result = arr
  result.add(newItem)

proc isAsciiSpace(ch: char): bool =
  ch in {' ', '\t', '\n', '\r', '\f', '\v'}

proc startsWithBomUtf8(s: string, i: int): bool =
  i + 2 < s.len and s[i] == '\xEF' and s[i + 1] == '\xBB' and s[i + 2] == '\xBF'

proc startsWithAt(s, prefix: string, i: int): bool =
  if i < 0 or i + prefix.len > s.len:
    return false
  s[i ..< i + prefix.len] == prefix

proc findDiscordLinkEnd(s: string, start: int): int =
  var i = start
  while i < s.len and not isAsciiSpace(s[i]):
    if startsWithBomUtf8(s, i):
      break
    if s[i] == '<':
      inc i
      break
    inc i
  if i <= start:
    return start

  var endPos = i
  while endPos > start and (s[endPos - 1] in {'"', '\'', ')', ',', '.', ':', ';', ']'} or isAsciiSpace(s[endPos - 1])):
    dec endPos
  if endPos <= start:
    return start
  endPos

proc isLinkStartAt(s: string, i: int): bool =
  (i + 7 < s.len and startsWithAt(s, "http://", i)) or (i + 8 < s.len and startsWithAt(s, "https://", i))

proc escapeDiscordTextChunk(s: string): string =
  result = newStringOfCap(s.len + 8)
  for ch in s:
    case ch
    of '\\', '_', '*', '~', '`', '|', '<', '#':
      result.add('\\')
      result.add(ch)
    else:
      result.add(ch)

proc escapeDiscordMarkdown*(s: string): string =
  if s.len == 0:
    return ""

  var i = 0
  var buf = newStringOfCap(s.len + 16)
  var chunkStart = 0
  while i < s.len:
    if isLinkStartAt(s, i):
      let prefixLen = if startsWithAt(s, "https://", i): 8 else: 7
      let endPos = findDiscordLinkEnd(s, i + prefixLen)
      if endPos > i + prefixLen - 1:
        if chunkStart < i:
          buf.add(escapeDiscordTextChunk(s[chunkStart ..< i]))
        buf.add(s[i ..< endPos])
        i = endPos
        chunkStart = i
        continue
    inc i
  if chunkStart < s.len:
    buf.add(escapeDiscordTextChunk(s[chunkStart .. ^1]))
  buf

proc applyEscapeFixer(text: string): string =
  ## Mirrors escapeFixer.ReplaceAllStringFunc(...) from Go implementation.
  result = text
  var i = 0
  while i + 4 <= result.len:
    if result[i] == '\\' and result[i + 1] == '_' and result[i + 2] == '_' and result[i + 3] != '_':
      result.insert("\\", i + 2)
      i += 5
      continue
    if result[i] == '\\' and result[i + 1] == '*' and result[i + 2] == '*' and result[i + 3] != '*':
      result.insert("\\", i + 2)
      i += 5
      continue
    inc i

proc replaceTagAndEveryoneWithHtml(text: string): string =
  var i = 0
  result = newStringOfCap(text.len + 32)
  while i < text.len:
    if text[i] == '<':
      let parsedTag = parseTag(text, i)
      if parsedTag.ok:
        result.add(defaultDiscordTagHtmlRenderer.renderDiscordMention(parsedTag.tag, entering = true))
        i += parsedTag.consumed
        continue
    if text[i] == '@':
      let parsedEveryone = defaultDiscordEveryoneParser.parse(text, i)
      if parsedEveryone.ok:
        result.add(defaultDiscordEveryoneHtmlRenderer.renderDiscordEveryone(parsedEveryone.node, entering = true))
        i += parsedEveryone.consumed
        continue
    result.add(text[i])
    inc i

proc renderDiscordMarkdownOnlyHTMLNoUnwrap*(
    text: string,
    allowInlineLinks: bool
): string =
  discard allowInlineLinks
  ## This is a compatibility-focused lightweight renderer:
  ## keep plain text, run escape fixer, and render Discord-native tags.
  replaceTagAndEveryoneWithHtml(applyEscapeFixer(text))

proc unwrapSingleParagraph(html: string): string =
  let trimmed = html.strip()
  if trimmed.startsWith("<p>") and trimmed.endsWith("</p>") and trimmed.len >= 7:
    trimmed[3 ..< trimmed.len - 4]
  else:
    html

proc renderDiscordMarkdownOnlyHTML*(
    text: string,
    allowInlineLinks: bool
): string =
  unwrapSingleParagraph(renderDiscordMarkdownOnlyHTMLNoUnwrap(text, allowInlineLinks))

proc hasAllowedMention(allowed: seq[string], mxid: string): bool =
  if allowed.len == 0:
    return true
  for item in allowed:
    if item == mxid:
      return true
  false

proc pillConverter*(
    displayname, mxid, eventID: string,
    ctx: var PillConvertContext
): string =
  if mxid.len == 0:
    return displayname

  var resolved = mxid
  case resolved[0]
  of '#':
    if ctx.resolveAliasRoom == nil:
      return displayname
    resolved = ctx.resolveAliasRoom(resolved)
    if resolved.len == 0:
      return displayname
    if resolved[0] != '!':
      return displayname
    if ctx.resolveRoomMention == nil:
      return displayname
    let mention = ctx.resolveRoomMention(resolved, eventID)
    if mention.len > 0:
      return mention
  of '!':
    if ctx.resolveRoomMention == nil:
      return displayname
    let mention = ctx.resolveRoomMention(resolved, eventID)
    if mention.len > 0:
      return mention
  of '@':
    if not hasAllowedMention(ctx.inputAllowedMentions, resolved):
      return displayname
    if ctx.resolveUserMention == nil:
      return displayname
    let mention = ctx.resolveUserMention(resolved)
    if mention.len == 0:
      return displayname
    ctx.allowedMentions = appendIfNotContains(ctx.allowedMentions, mention)
    return "<@" & mention & ">"
  else:
    discard
  displayname

proc parseMatrixHTML*(
    content: MatrixHtmlMessage,
    allowedLinkPreviews: seq[string],
    ctx: var PillConvertContext
): tuple[text: string, allowedMentions: MessageAllowedMentions] =
  discard allowedLinkPreviews
  var allowed = MessageAllowedMentions(users: @[], repliedUser: true)
  var workCtx = ctx
  workCtx.inputAllowedMentions = content.mentionedUserIds

  if content.format == MatrixHtmlFormat and content.formattedBody.len > 0:
    ## Lightweight compatibility parser for now:
    ## strip common HTML tags, keep text content, then apply markdown escaping.
    var plain = content.formattedBody
    for needle in ["<br>", "<br/>", "<br />"]:
      plain = plain.replace(needle, "\n")
    for needle in ["<p>", "</p>", "<strong>", "</strong>", "<b>", "</b>", "<em>", "</em>", "<i>", "</i>", "<u>", "</u>", "<code>", "</code>", "<pre>", "</pre>"]:
      plain = plain.replace(needle, "")
    let escaped = escapeDiscordMarkdown(plain)
    return (escaped, allowed)

  (escapeDiscordMarkdown(content.body), allowed)
