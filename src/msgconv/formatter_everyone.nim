## Discord @everyone/@here parser and HTML renderer helpers.

import std/[strutils]

type
  AstDiscordEveryone* = object
    onlyHere*: bool

  DiscordEveryoneParser* = object
  DiscordEveryoneHtmlRenderer* = object
  DiscordEveryoneExtension* = object

const
  DiscordEveryoneKind* = "DiscordEveryone"

let
  defaultDiscordEveryoneParser* = DiscordEveryoneParser()
  defaultDiscordEveryoneHtmlRenderer* = DiscordEveryoneHtmlRenderer()
  ExtDiscordEveryone* = DiscordEveryoneExtension()

proc dump*(n: AstDiscordEveryone, source = "", level = 0): string =
  let mention = if n.onlyHere: "@here" else: "@everyone"
  "AstDiscordEveryone(level=" & $level & ", mention=" & mention & ", source=" & source & ")"

proc kind*(n: AstDiscordEveryone): string =
  discard n
  DiscordEveryoneKind

proc toDiscordString*(n: AstDiscordEveryone): string =
  if n.onlyHere:
    "@here"
  else:
    "@everyone"

proc trigger*(s: DiscordEveryoneParser): seq[char] =
  discard s
  @['@']

proc parse*(
    s: DiscordEveryoneParser,
    input: string,
    pos = 0
): tuple[ok: bool, node: AstDiscordEveryone, consumed: int] =
  discard s
  if pos < 0 or pos >= input.len:
    return (false, AstDiscordEveryone(), 0)
  let tail = input[pos .. ^1]
  if tail.startsWith("@everyone"):
    return (true, AstDiscordEveryone(onlyHere: false), "@everyone".len)
  if tail.startsWith("@here"):
    return (true, AstDiscordEveryone(onlyHere: true), "@here".len)
  (false, AstDiscordEveryone(), 0)

proc closeBlock*(s: DiscordEveryoneParser) =
  discard s

proc registerFuncs*(r: DiscordEveryoneHtmlRenderer): seq[string] =
  discard r
  @[DiscordEveryoneKind]

proc renderDiscordEveryone*(
    r: DiscordEveryoneHtmlRenderer,
    node: AstDiscordEveryone,
    entering = true
): string =
  discard r
  if not entering:
    return ""
  let klass = if node.onlyHere: "here" else: "everyone"
  """<span class="discord-mention-""" & klass & """">@room</span>"""

proc extend*(e: DiscordEveryoneExtension): tuple[parserPriority: int, rendererPriority: int] =
  discard e
  (600, 600)
