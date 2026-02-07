## Discord mention/tag parser and HTML renderer helpers.

import std/[strformat, strutils, times]

type
  DiscordTagKind* = enum
    dtkUserMention
    dtkRoleMention
    dtkChannelMention
    dtkTimestamp
    dtkCustomEmoji

  ParsedDiscordTag* = object
    kind*: DiscordTagKind
    id*: uint64
    hasNick*: bool
    guildId*: uint64
    channelName*: string
    timestamp*: int64
    style*: char
    emojiName*: string
    animated*: bool

  DiscordTagParser* = object
  DiscordTagHtmlRenderer* = object
  DiscordTagExtension* = object

  DiscordUserInfo* = object
    mxid*: string
    name*: string

  DiscordRoleInfo* = object
    name*: string
    color*: int

  DiscordChannelInfo* = object
    name*: string
    mxid*: string

  DiscordTagRenderContext* = object
    resolveUser*: proc(id: uint64): DiscordUserInfo {.closure.}
    resolveRole*: proc(id: uint64): DiscordRoleInfo {.closure.}
    resolveChannel*: proc(id: uint64): DiscordChannelInfo {.closure.}
    resolveEmojiMxc*: proc(id: uint64, name: string, animated: bool): string {.closure.}

const
  DiscordTagKindName* = "DiscordTag"

let
  defaultDiscordTagParser* = DiscordTagParser()
  defaultDiscordTagHtmlRenderer* = DiscordTagHtmlRenderer()
  ExtDiscordTag* = DiscordTagExtension()

proc dump*(n: ParsedDiscordTag, source = "", level = 0): string =
  "ParsedDiscordTag(level=" & $level & ", kind=" & $n.kind & ", source=" & source & ")"

proc kind*(n: ParsedDiscordTag): string =
  discard n
  DiscordTagKindName

proc userMentionString*(id: uint64, hasNick = false): string =
  if hasNick:
    "<@!" & $id & ">"
  else:
    "<@" & $id & ">"

proc roleMentionString*(id: uint64): string =
  "<@&" & $id & ">"

proc channelMentionString*(id, guildId: uint64, channelName = ""): string =
  if guildId != 0 and channelName.len > 0:
    "<#" & $id & ":" & $guildId & ":" & channelName & ">"
  else:
    "<#" & $id & ">"

proc timestampStyleFormat*(style: char): string =
  case style
  of 't':
    "HH:mm 'UTC'"
  of 'T':
    "HH:mm:ss 'UTC'"
  of 'd':
    "yyyy-MM-dd 'UTC'"
  of 'D':
    "d MMMM yyyy 'UTC'"
  of 'F':
    "dddd, d MMMM yyyy HH:mm 'UTC'"
  of 'f':
    "d MMMM yyyy HH:mm 'UTC'"
  else:
    "d MMMM yyyy HH:mm 'UTC'"

proc timestampString*(timestamp: int64, style: char): string =
  if style == 'f':
    "<t:" & $timestamp & ">"
  else:
    "<t:" & $timestamp & ":" & $style & ">"

proc customEmojiString*(id: uint64, name: string, animated = false): string =
  if animated:
    "<a" & name & $id & ">"
  else:
    "<" & name & $id & ">"

proc trigger*(s: DiscordTagParser): seq[char] =
  discard s
  @['<']

proc parseUInt64(input: string, i: var int): tuple[ok: bool, value: uint64] =
  let start = i
  while i < input.len and input[i] in {'0' .. '9'}:
    inc i
  if i == start:
    return (false, 0'u64)
  try:
    (true, parseBiggestUInt(input[start ..< i]).uint64)
  except ValueError:
    (false, 0'u64)

proc parseTag*(
    input: string,
    pos = 0
): tuple[ok: bool, tag: ParsedDiscordTag, consumed: int] =
  if pos < 0 or pos >= input.len or input[pos] != '<':
    return (false, ParsedDiscordTag(), 0)
  var i = pos + 1
  if i >= input.len:
    return (false, ParsedDiscordTag(), 0)

  if input[i] == '@':
    inc i
    var mentionKind = input[i]
    var hasNick = false
    var isRole = false
    if mentionKind == '!':
      hasNick = true
      inc i
    elif mentionKind == '&':
      isRole = true
      inc i
    let parsedId = parseUInt64(input, i)
    if not parsedId.ok or i >= input.len or input[i] != '>':
      return (false, ParsedDiscordTag(), 0)
    inc i
    if isRole:
      return (true, ParsedDiscordTag(kind: dtkRoleMention, id: parsedId.value), i - pos)
    return (true, ParsedDiscordTag(kind: dtkUserMention, id: parsedId.value, hasNick: hasNick), i - pos)

  if input[i] == '#':
    inc i
    let parsedChan = parseUInt64(input, i)
    if not parsedChan.ok:
      return (false, ParsedDiscordTag(), 0)
    var guildId = 0'u64
    var channelName = ""
    if i < input.len and input[i] == ':':
      inc i
      let parsedGuild = parseUInt64(input, i)
      if not parsedGuild.ok or i >= input.len or input[i] != ':':
        return (false, ParsedDiscordTag(), 0)
      guildId = parsedGuild.value
      inc i
      let startName = i
      while i < input.len and input[i] != '>':
        inc i
      if i == startName:
        return (false, ParsedDiscordTag(), 0)
      channelName = input[startName ..< i]
    if i >= input.len or input[i] != '>':
      return (false, ParsedDiscordTag(), 0)
    inc i
    return (true, ParsedDiscordTag(kind: dtkChannelMention, id: parsedChan.value, guildId: guildId, channelName: channelName), i - pos)

  if input[i] == 't':
    inc i
    if i >= input.len or input[i] != ':':
      return (false, ParsedDiscordTag(), 0)
    inc i
    let parsedTs = parseUInt64(input, i)
    if not parsedTs.ok:
      return (false, ParsedDiscordTag(), 0)
    var style = 'f'
    if i < input.len and input[i] == ':':
      inc i
      if i >= input.len or input[i] notin {'t', 'T', 'd', 'D', 'f', 'F', 'R'}:
        return (false, ParsedDiscordTag(), 0)
      style = input[i]
      inc i
    if i >= input.len or input[i] != '>':
      return (false, ParsedDiscordTag(), 0)
    inc i
    return (true, ParsedDiscordTag(kind: dtkTimestamp, id: parsedTs.value, timestamp: parsedTs.value.int64, style: style), i - pos)

  var animated = false
  if input[i] == 'a' and i + 1 < input.len and input[i + 1] == ':':
    animated = true
    i += 2
  elif input[i] == ':':
    inc i
  else:
    return (false, ParsedDiscordTag(), 0)

  let nameStart = i
  while i < input.len and (input[i] in {'a' .. 'z'} or input[i] in {'A' .. 'Z'} or input[i] in {'0' .. '9'} or input[i] == '_'):
    inc i
  if i == nameStart or i >= input.len or input[i] != ':':
    return (false, ParsedDiscordTag(), 0)
  let emojiName = ":" & input[nameStart ..< i] & ":"
  inc i
  let parsedEmojiId = parseUInt64(input, i)
  if not parsedEmojiId.ok or i >= input.len or input[i] != '>':
    return (false, ParsedDiscordTag(), 0)
  inc i
  (
    true,
    ParsedDiscordTag(kind: dtkCustomEmoji, id: parsedEmojiId.value, emojiName: emojiName, animated: animated),
    i - pos
  )

proc parse*(
    s: DiscordTagParser,
    input: string,
    pos = 0
): tuple[ok: bool, tag: ParsedDiscordTag, consumed: int] =
  discard s
  parseTag(input, pos)

proc closeBlock*(s: DiscordTagParser) =
  discard s

proc registerFuncs*(r: DiscordTagHtmlRenderer): seq[string] =
  discard r
  @[DiscordTagKindName]

proc roundDiv(n, d: int64): int64 =
  (n + d div 2) div d

proc relativeTimeFormat*(ts: Time, now = getTime()): string =
  let dt = ts.utc
  if dt.year >= 2262:
    return "date out of range for relative format"

  var deltaMs = (ts - now).inMilliseconds
  let future = deltaMs >= 0
  if deltaMs < 0:
    deltaMs = -deltaMs

  var count = 0'i64
  var unit = "second"
  if deltaMs < 1_000'i64:
    count = deltaMs
    unit = "millisecond"
  elif deltaMs < 60_000'i64:
    count = roundDiv(deltaMs, 1_000)
    unit = "second"
  elif deltaMs < 3_600_000'i64:
    count = roundDiv(deltaMs, 60_000)
    unit = "minute"
  elif deltaMs < 86_400_000'i64:
    count = roundDiv(deltaMs, 3_600_000)
    unit = "hour"
  elif deltaMs < 2_592_000_000'i64:
    count = roundDiv(deltaMs, 86_400_000)
    unit = "day"
  elif deltaMs < 31_536_000_000'i64:
    count = roundDiv(deltaMs, 2_592_000_000)
    unit = "month"
  else:
    count = roundDiv(deltaMs, 31_536_000_000)
    unit = "year"

  let diff =
    if count == 1:
      "a " & unit
    else:
      $count & " " & unit & "s"
  if future:
    "in " & diff
  else:
    diff & " ago"

proc renderTimestamp(ts: ParsedDiscordTag): string =
  let t = fromUnix(ts.timestamp).utc
  let formatted =
    if ts.style == 'R':
      relativeTimeFormat(fromUnix(ts.timestamp))
    else:
      t.format(timestampStyleFormat(ts.style))
  let fullHuman = t.format(timestampStyleFormat('F'))
  let fullRfc = t.format("yyyy-MM-dd'T'HH:mm:ss'.000+0000'")
  fmt"""<time title="{fullHuman}" datetime="{fullRfc}" data-discord-style="{ts.style}"><strong>{formatted}</strong></time>"""

proc matrixToUrl(mxid: string): string =
  "https://matrix.to/#/" & mxid

proc renderDiscordMention*(
    r: DiscordTagHtmlRenderer,
    tag: ParsedDiscordTag,
    entering = true,
    ctx = DiscordTagRenderContext()
): string =
  discard r
  if not entering:
    return ""

  case tag.kind
  of dtkUserMention:
    if ctx.resolveUser != nil:
      let user = ctx.resolveUser(tag.id)
      if user.mxid.len > 0:
        let name = if user.name.len > 0: user.name else: user.mxid
        return fmt"""<a href="{matrixToUrl(user.mxid)}">{name}</a>"""
    userMentionString(tag.id, tag.hasNick)
  of dtkRoleMention:
    if ctx.resolveRole != nil:
      let role = ctx.resolveRole(tag.id)
      if role.name.len > 0:
        return fmt"""<font color="#{role.color and 0xFFFFFF:06x}"><strong>@{role.name}</strong></font>"""
    roleMentionString(tag.id)
  of dtkChannelMention:
    if ctx.resolveChannel != nil:
      let ch = ctx.resolveChannel(tag.id)
      if ch.name.len > 0 and ch.mxid.len > 0:
        return fmt"""<a href="{matrixToUrl(ch.mxid)}">{ch.name}</a>"""
      if ch.name.len > 0:
        return ch.name
    channelMentionString(tag.id, tag.guildId, tag.channelName)
  of dtkCustomEmoji:
    if ctx.resolveEmojiMxc != nil:
      let mxc = ctx.resolveEmojiMxc(tag.id, tag.emojiName, tag.animated)
      if mxc.len > 0:
        var attrs = "data-mx-emoticon"
        if tag.animated:
          attrs &= " data-mau-animated-emoji"
        return fmt"""<img {attrs} src="{mxc}" alt="{tag.emojiName}" title="{tag.emojiName}" height="32"/>"""
    customEmojiString(tag.id, tag.emojiName, tag.animated)
  of dtkTimestamp:
    renderTimestamp(tag)

proc extend*(e: DiscordTagExtension): tuple[parserPriority: int, rendererPriority: int] =
  discard e
  (600, 600)
