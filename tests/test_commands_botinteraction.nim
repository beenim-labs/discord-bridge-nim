import std/[json, strutils, tables, unittest]
import bridge/commands/bot_interaction

proc opt(
    name: string,
    optionType: int,
    required = false,
    description = "",
    options: seq[CommandOption] = @[]
): CommandOption =
  CommandOption(
    name: name,
    description: if description.len > 0: description else: name,
    required: required,
    optionType: optionType,
    options: options
  )

proc cmd(name, description: string, options: seq[CommandOption] = @[]): ApplicationCommand =
  ApplicationCommand(name: name, description: description, options: options)

suite "commands bot interaction":
  test "option type names and option value parsing":
    check getCommandOptionTypeName(OptionString) == "string"
    check getCommandOptionTypeName(OptionAttachment) == "attachment (unsupported)"
    check getCommandOptionTypeName(999).contains("unknown type")

    let s = parseCommandOptionValue(OptionString, "hello")
    check s.ok
    check s.parsed.getStr() == "hello"

    let i = parseCommandOptionValue(OptionInteger, "42")
    check i.ok
    check i.parsed.getBiggestInt() == 42

    let b = parseCommandOptionValue(OptionBoolean, "TRUE")
    check b.ok
    check b.parsed.getBool()

    let f = parseCommandOptionValue(OptionNumber, "3.5")
    check f.ok
    check abs(f.parsed.getFloat() - 3.5) < 0.0001

    let unsupported = parseCommandOptionValue(OptionUser, "x")
    check not unsupported.ok
    check unsupported.err.contains("aren't supported")

  test "indent and format helpers":
    check indent("a\nb", "  ") == "  a\n  b"

    let optionTree = opt(
      "ban",
      OptionSubCommand,
      options = @[
        opt("reason", OptionString, required = true, description = "why"),
        opt("silent", OptionBoolean, required = false, description = "silent")
      ]
    )
    let command = cmd("mod", "Moderation", @[optionTree])

    let formattedOpt = formatOption(optionTree)
    check formattedOpt.contains("`ban`: subcommand")
    check formattedOpt.contains("`reason`: string - why")
    check formattedOpt.contains("(required)")

    let formattedCmd = formatCommand(command)
    check formattedCmd.contains("`$cmdprefix exec mod [arg=value ...]`")
    check formattedCmd.contains("Moderation")

  test "parse command options and execute command":
    let command = cmd("mod", "Moderation", @[
      opt("ban", OptionSubCommand, options = @[
        opt("reason", OptionString, required = true),
        opt("days", OptionInteger)
      ]),
      opt("silent", OptionBoolean)
    ])

    var named = initTable[string, string]()
    named["reason"] = "spam"
    named["days"] = "3"
    named["silent"] = "true"

    let parsed = parseCommandOptions(command.options, @["ban"], named)
    check parsed.ok
    check parsed.res.len == 2
    check parsed.res[0].name == "ban"
    check parsed.res[0].options.len == 2
    check parsed.res[1].name == "silent"
    check parsed.res[1].value.getBool()

    let executed = executeCommand(command, @["ban", "reason=spam", "days=3", "silent=true"])
    check executed.ok
    check executed.res.len == 2

    let missing = executeCommand(command, @["ban"])
    check not missing.ok
    check missing.err.contains("missing required parameter reason")

  test "getCommand search caches and help/search command flow":
    var calls = 0
    let portal = newCommandPortalContext(proc(query: string): tuple[ok: bool, results: seq[ApplicationCommand], err: string] =
      inc calls
      (
        true,
        @[
          cmd("ping", "Ping test"),
          cmd("echo", "Echo text", @[opt("text", OptionString, required = true)])
        ],
        ""
      )
    )

    let fetched = portal.getCommand("ping")
    check fetched.found
    check calls == 1

    let fetchedCached = portal.getCommand("ping")
    check fetchedCached.found
    check calls == 1

    let searchEvent = newBotCommandEvent(portal, @["search", "pi"], "search pi")
    fnCommands(searchEvent)
    check searchEvent.replies.len == 1
    check searchEvent.replies[0].contains("Found results:")
    check portal.commands.hasKey("ping")

    let helpEvent = newBotCommandEvent(portal, @["help", "echo"], "help echo")
    fnCommands(helpEvent)
    check helpEvent.replies.len == 1
    check helpEvent.replies[0].contains("`$cmdprefix exec echo <arg=value ...>`")

  test "fnExec sends interactions and records pending nonce":
    let portal = newCommandPortalContext(proc(query: string): tuple[ok: bool, results: seq[ApplicationCommand], err: string] =
      (true, @[cmd("echo", "Echo", @[opt("text", OptionString, required = true)])], "")
    )
    let state = newBotInteractionState()

    var sendCalled = false
    var sentNonce = ""
    var sentOptions: seq[CommandOptionInput] = @[]
    let sendProc: SendInteractionProc =
      proc(command: ApplicationCommand, options: seq[CommandOptionInput], nonce: string): tuple[ok: bool, err: string] {.closure.} =
        sendCalled = true
        sentNonce = nonce
        sentOptions = options
        (true, "")

    let ev = newBotCommandEvent(
      portal,
      @["echo", "text=hello"],
      "echo text=hello",
      sendProc = sendProc,
      interactionState = state
    )
    fnExec(ev)
    if ev.replies.len > 0:
      checkpoint("fnExec unexpected reply: " & ev.replies[0])
    check sendCalled
    check ev.replies.len == 0
    check sentNonce.len > 0
    check state.pendingByNonce.hasKey(sentNonce)
    check sentOptions.len == 1
    if sentOptions.len > 0:
      check sentOptions[0].name == "text"
      check sentOptions[0].value.getStr() == "hello"

    let expired = expirePendingInteractions(state, timeoutMs = 0, nowOverrideMs = state.pendingByNonce[sentNonce])
    check expired.len == 1
    check expired[0] == sentNonce
    check not state.pendingByNonce.hasKey(sentNonce)

  test "fnExec reports parse and send errors":
    let portal = newCommandPortalContext(proc(query: string): tuple[ok: bool, results: seq[ApplicationCommand], err: string] =
      (true, @[cmd("echo", "Echo", @[opt("text", OptionString, required = true)])], "")
    )
    let state = newBotInteractionState()

    let parseErrEv = newBotCommandEvent(portal, @["echo"], "echo")
    fnExec(parseErrEv)
    check parseErrEv.replies.len == 1
    check parseErrEv.replies[0].contains("Error parsing arguments:")

    let sendErrEv = newBotCommandEvent(
      portal,
      @["echo", "text=hello"],
      "echo text=hello",
      sendProc = proc(command: ApplicationCommand, options: seq[CommandOptionInput], nonce: string): tuple[ok: bool, err: string] {.closure.} =
        (false, "boom"),
      interactionState = state
    )
    fnExec(sendErrEv)
    check sendErrEv.replies.len == 1
    check sendErrEv.replies[0].contains("Error sending interaction: boom")
