## Small YAML subset parser for bridge config/registration files.
## Supports key/value mappings and indentation-based sections.

import std/[tables, strutils, sequtils]

type
  YamlMap* = Table[string, string]

proc dequote(v: string): string =
  result = v.strip()
  if result.len >= 2 and ((result[0] == '"' and result[^1] == '"') or (result[0] == '\'' and result[^1] == '\'')):
    result = result[1 .. ^2]

proc parseValue(line: string): tuple[key: string, value: string, hasValue: bool] =
  let idx = line.find(':')
  if idx < 0:
    return ("", "", false)
  let key = line[0 ..< idx].strip()
  if key.len == 0:
    return ("", "", false)
  let rawValue = if idx + 1 < line.len: line[idx + 1 .. ^1] else: ""
  (key, dequote(rawValue), rawValue.strip().len > 0)

proc stripComment(line: string): string =
  var inSingle = false
  var inDouble = false
  for i, ch in line:
    case ch
    of '\'':
      if not inDouble:
        inSingle = not inSingle
    of '"':
      if not inSingle:
        inDouble = not inDouble
    of '#':
      if not inSingle and not inDouble:
        return line[0 ..< i]
    else:
      discard
  line

proc leadingSpaces(line: string): int =
  result = 0
  for ch in line:
    if ch == ' ':
      inc result
    elif ch == '\t':
      result += 2
    else:
      break

proc parseSimpleYaml*(content: string): YamlMap =
  result = initTable[string, string]()
  var stack: seq[tuple[indent: int, key: string]] = @[]

  for raw in content.splitLines():
    var line = stripComment(raw).strip(leading = false, trailing = true)
    if line.strip().len == 0:
      continue

    let indent = leadingSpaces(line)
    line = line.strip()

    if line.startsWith("- "):
      # List handling is intentionally out-of-scope for this parser.
      continue

    let parsed = parseValue(line)
    if parsed.key.len == 0:
      continue

    while stack.len > 0 and indent <= stack[^1].indent:
      discard stack.pop()

    if not parsed.hasValue:
      stack.add((indent, parsed.key))
      continue

    var full: seq[string] = stack.mapIt(it.key)
    full.add(parsed.key)
    result[full.join(".")] = parsed.value.strip()

proc parseSimpleYamlFile*(path: string): YamlMap =
  parseSimpleYaml(readFile(path))
