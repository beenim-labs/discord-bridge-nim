## Bot interaction command helpers adapted from commands_botinteraction.go.

import std/[cmdline, json, random, strutils, tables, times]

const
  OptionSubCommand* = 1
  OptionSubCommandGroup* = 2
  OptionString* = 3
  OptionInteger* = 4
  OptionBoolean* = 5
  OptionUser* = 6
  OptionChannel* = 7
  OptionRole* = 8
  OptionMentionable* = 9
  OptionNumber* = 10
  OptionAttachment* = 11

type
  CommandOption* = ref object
    name*: string
    description*: string
    required*: bool
    optionType*: int
    options*: seq[CommandOption]

  ApplicationCommand* = ref object
    name*: string
    description*: string
    options*: seq[CommandOption]

  CommandOptionInput* = ref object
    optionType*: int
    name*: string
    value*: JsonNode
    options*: seq[CommandOptionInput]

  SearchCommandProc* = proc(query: string): tuple[ok: bool, results: seq[ApplicationCommand], err: string] {.closure.}
  SendInteractionProc* = proc(command: ApplicationCommand, options: seq[CommandOptionInput], nonce: string): tuple[ok: bool, err: string] {.closure.}

  CommandPortalContext* = ref object
    commands*: Table[string, ApplicationCommand]
    searchProc*: SearchCommandProc

  BotInteractionState* = ref object
    pendingByNonce*: Table[string, int64]

  BotCommandEvent* = ref object
    portal*: CommandPortalContext
    args*: seq[string]
    rawArgs*: string
    replies*: seq[string]
    sendProc*: SendInteractionProc
    interactionState*: BotInteractionState

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

proc canonicalName(name: string): string =
  name.toLowerAscii()

proc newCommandPortalContext*(searchProc: SearchCommandProc = nil): CommandPortalContext =
  new(result)
  result.searchProc = searchProc
  result.commands = initTable[string, ApplicationCommand]()

proc newBotInteractionState*(): BotInteractionState =
  new(result)
  result.pendingByNonce = initTable[string, int64]()

proc newBotCommandEvent*(
    portal: CommandPortalContext,
    args: seq[string],
    rawArgs: string,
    sendProc: SendInteractionProc = nil,
    interactionState: BotInteractionState = nil
): BotCommandEvent =
  BotCommandEvent(
    portal: portal,
    args: args,
    rawArgs: rawArgs,
    replies: @[],
    sendProc: sendProc,
    interactionState: interactionState
  )

proc reply*(ce: BotCommandEvent, message: string) =
  if ce == nil:
    return
  ce.replies.add(message)

proc randomAlphaNum(length: int): string =
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(length)
  for i in 0 ..< length:
    result[i] = chars[rand(chars.high)]

proc generateNonce*(): string =
  randomize()
  randomAlphaNum(32)

proc settleInteraction*(state: BotInteractionState, nonce: string) =
  if state == nil or nonce.len == 0:
    return
  if state.pendingByNonce.hasKey(nonce):
    state.pendingByNonce.del(nonce)

proc expirePendingInteractions*(
    state: BotInteractionState,
    timeoutMs = 10_000'i64,
    nowOverrideMs = -1'i64
): seq[string] =
  result = @[]
  if state == nil:
    return
  let nowVal = if nowOverrideMs >= 0: nowOverrideMs else: nowMs()
  for nonce, createdAt in state.pendingByNonce.pairs:
    if nowVal - createdAt >= timeoutMs:
      result.add(nonce)
  for nonce in result:
    state.pendingByNonce.del(nonce)

proc getCommand*(
    portal: CommandPortalContext,
    command: string
): tuple[found: bool, cmd: ApplicationCommand, err: string] =
  if portal == nil:
    return (false, nil, "portal context is nil")
  let key = canonicalName(command)
  if portal.commands.hasKey(key):
    return (true, portal.commands[key], "")
  if portal.searchProc == nil:
    return (false, nil, "")

  let search = portal.searchProc(command)
  if not search.ok:
    return (false, nil, search.err)
  for result in search.results:
    if canonicalName(result.name) == key:
      portal.commands[key] = result
      return (true, result, "")
  (false, nil, "")

proc getCommandOptionTypeName*(optType: int): string =
  case optType
  of OptionSubCommand:
    "subcommand"
  of OptionSubCommandGroup:
    "subcommand group (unsupported)"
  of OptionString:
    "string"
  of OptionInteger:
    "integer"
  of OptionBoolean:
    "boolean"
  of OptionUser:
    "user (unsupported)"
  of OptionChannel:
    "channel (unsupported)"
  of OptionRole:
    "role (unsupported)"
  of OptionMentionable:
    "mentionable (unsupported)"
  of OptionNumber:
    "number"
  of OptionAttachment:
    "attachment (unsupported)"
  else:
    "unknown type " & $optType

proc parseGoBool(value: string): tuple[ok: bool, parsed: bool] =
  case value.toLowerAscii()
  of "1", "t", "true", "y", "yes", "on":
    (true, true)
  of "0", "f", "false", "n", "no", "off":
    (true, false)
  else:
    (false, false)

proc parseCommandOptionValue*(optType: int, value: string): tuple[ok: bool, parsed: JsonNode, err: string] =
  try:
    case optType
    of OptionSubCommandGroup:
      (false, newJNull(), "subcommand groups aren't supported")
    of OptionString:
      (true, %value, "")
    of OptionInteger:
      (true, %parseBiggestInt(value), "")
    of OptionBoolean:
      let boolVal = parseGoBool(value)
      if not boolVal.ok:
        return (false, newJNull(), "invalid boolean syntax")
      (true, %boolVal.parsed, "")
    of OptionUser:
      (false, newJNull(), "user options aren't supported")
    of OptionChannel:
      (false, newJNull(), "channel options aren't supported")
    of OptionRole:
      (false, newJNull(), "role options aren't supported")
    of OptionMentionable:
      (false, newJNull(), "mentionable options aren't supported")
    of OptionNumber:
      (true, %parseFloat(value), "")
    of OptionAttachment:
      (false, newJNull(), "attachment options aren't supported")
    else:
      (false, newJNull(), "unknown option type " & $optType)
  except ValueError as e:
    (false, newJNull(), e.msg)

proc indent*(text, withPrefix: string): string =
  let split = text.splitLines()
  var parts: seq[string] = @[]
  for part in split:
    parts.add(withPrefix & part)
  parts.join("\n")

proc formatOption*(opt: CommandOption): string =
  if opt == nil:
    return ""
  var argText = "* `" & opt.name & "`: " & getCommandOptionTypeName(opt.optionType)
  if opt.description.toLowerAscii() != opt.name.toLowerAscii():
    argText &= " - " & opt.description
  if opt.required:
    argText &= " (required)"
  if opt.options.len > 0:
    var subopts: seq[string] = @[]
    for subopt in opt.options:
      subopts.add(indent(formatOption(subopt), "  "))
    argText &= "\n" & subopts.join("\n")
  argText

proc formatCommand*(cmd: ApplicationCommand): string =
  if cmd == nil:
    return ""
  var baseText = "$cmdprefix exec " & cmd.name
  if cmd.options.len > 0:
    var args: seq[string] = @[]
    var argPlaceholder = "[arg=value ...]"
    for opt in cmd.options:
      args.add(formatOption(opt))
      if opt.required:
        argPlaceholder = "<arg=value ...>"
    baseText = "`" & baseText & " " & argPlaceholder & "` - " & cmd.description & "\n" & args.join("\n")
  else:
    baseText = "`" & baseText & "` - " & cmd.description
  baseText

proc parseCommandOptions*(
    opts: seq[CommandOption],
    subcommands: seq[string],
    namedArgs: Table[string, string]
): tuple[ok: bool, res: seq[CommandOptionInput], err: string] =
  result = (true, @[], "")
  var subcommandDone = false
  var remainingSubcommands = subcommands

  for opt in opts:
    if opt == nil:
      continue
    var optRes = CommandOptionInput(
      optionType: opt.optionType,
      name: opt.name,
      value: newJNull(),
      options: @[]
    )
    if opt.optionType == OptionSubCommand:
      if (not subcommandDone) and remainingSubcommands.len > 0 and remainingSubcommands[0] == opt.name:
        subcommandDone = true
        let rest = if remainingSubcommands.len > 1: remainingSubcommands[1 .. ^1] else: @[]
        let nested = parseCommandOptions(opt.options, rest, namedArgs)
        if not nested.ok:
          return (false, @[], "error parsing subcommand " & opt.name & ": " & nested.err)
        optRes.options = nested.res
        remainingSubcommands = rest
      else:
        continue
    elif namedArgs.hasKey(opt.name):
      let parsed = parseCommandOptionValue(opt.optionType, namedArgs[opt.name])
      if not parsed.ok:
        return (false, @[], "error parsing parameter " & opt.name & ": " & parsed.err)
      optRes.value = parsed.parsed
    elif opt.required:
      case opt.optionType
      of OptionSubCommandGroup, OptionUser, OptionChannel, OptionRole, OptionMentionable, OptionAttachment:
        return (false, @[], "missing required parameter " & opt.name & " (which is not supported by the bridge)")
      else:
        return (false, @[], "missing required parameter " & opt.name)
    else:
      continue
    result.res.add(optRes)

  if remainingSubcommands.len > 0:
    return (false, @[], "unparsed subcommands left over (did you forget quoting for parameters with spaces?)")

proc executeCommand*(
    cmd: ApplicationCommand,
    args: seq[string]
): tuple[ok: bool, res: seq[CommandOptionInput], err: string] =
  if cmd == nil:
    return (false, @[], "command is nil")
  var namedArgs = initTable[string, string]()
  var positional: seq[string] = @[]
  for arg in args:
    let idx = arg.find('=')
    if idx > 0:
      namedArgs[arg[0 ..< idx]] = arg[idx + 1 .. ^1]
    else:
      positional.add(arg)
  parseCommandOptions(cmd.options, positional, namedArgs)

proc fnCommands*(ce: BotCommandEvent) =
  if ce == nil:
    return
  if ce.args.len < 2:
    ce.reply("**Usage**: `$cmdprefix commands search <_query_>` OR `$cmdprefix commands help <_command_>`")
    return
  let subcmd = ce.args[0].toLowerAscii()
  if subcmd == "search":
    if ce.portal == nil or ce.portal.searchProc == nil:
      ce.reply("Error searching for commands: command search is not configured")
      return
    let search = ce.portal.searchProc(ce.args[1])
    if not search.ok:
      ce.reply("Error searching for commands: " & search.err)
      return

    var formatted: seq[string] = @[]
    for result in search.results:
      ce.portal.commands[canonicalName(result.name)] = result
      var line = indent(formatCommand(result), "  ")
      if line.len > 1:
        line = "*" & line[1 .. ^1]
      formatted.add(line)
    ce.reply("Found results:\n" & formatted.join("\n"))
  elif subcmd == "help":
    if ce.portal == nil:
      ce.reply("Error searching for commands: portal context is nil")
      return
    let command = ce.args[1].toLowerAscii()
    let fetched = ce.portal.getCommand(command)
    if fetched.err.len > 0:
      ce.reply("Error searching for commands: " & fetched.err)
    elif not fetched.found:
      ce.reply("Command \"" & command & "\" not found")
    else:
      ce.reply(formatCommand(fetched.cmd))

proc fnExec*(ce: BotCommandEvent) =
  if ce == nil:
    return
  if ce.args.len == 0:
    ce.reply("**Usage**: `$cmdprefix exec <command> [arg=value ...]`")
    return

  var parsedArgs: seq[string] = @[]
  try:
    parsedArgs = parseCmdLine(ce.rawArgs)
  except ValueError as e:
    ce.reply("Error parsing args with shlex: " & e.msg)
    return

  if parsedArgs.len == 0:
    ce.reply("**Usage**: `$cmdprefix exec <command> [arg=value ...]`")
    return

  if ce.portal == nil:
    ce.reply("Error searching for commands: portal context is nil")
    return

  let command = parsedArgs[0].toLowerAscii()
  let fetched = ce.portal.getCommand(command)
  if fetched.err.len > 0:
    ce.reply("Error searching for commands: " & fetched.err)
    return
  if not fetched.found:
    ce.reply("Command \"" & command & "\" not found")
    return

  let options = executeCommand(fetched.cmd, (if parsedArgs.len > 1: parsedArgs[1 .. ^1] else: @[]))
  if not options.ok:
    ce.reply("Error parsing arguments: " & options.err & "\n\n**Usage:** " & formatCommand(fetched.cmd))
    return

  let nonce = generateNonce()
  if ce.interactionState != nil:
    ce.interactionState.pendingByNonce[nonce] = nowMs()

  if ce.sendProc == nil:
    if ce.interactionState != nil:
      ce.interactionState.settleInteraction(nonce)
    ce.reply("Error sending interaction: interaction sender is not configured")
    return

  let sent = ce.sendProc(fetched.cmd, options.res, nonce)
  if not sent.ok:
    if ce.interactionState != nil:
      ce.interactionState.settleInteraction(nonce)
    ce.reply("Error sending interaction: " & sent.err)
