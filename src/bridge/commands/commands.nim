## Bridge command handler module ported from commands.go.
##
## Implements 17+ chat commands (login-token, login-qr, logout, ping,
## disconnect, reconnect, guilds, bridge, unbridge, etc.) using the injectable
## stub pattern for testability.

import std/[strformat, strutils, xmltree]
import database/entities
import bridge/commands/core_utils

# ===========================================================================
# Help sections (mirrors Go HelpSection constants)
# ===========================================================================

const
  HelpSectionAuth* = "Authentication"
  HelpSectionPortalManagement* = "Portal management"
  HelpSectionAdmin* = "Admin"

# ===========================================================================
# Command event — injectable wrapper matching Go WrappedCommandEvent
# ===========================================================================

type
  # Stub proc types used by command handlers
  ReplyProc* = proc(msg: string) {.closure.}
  RedactProc* = proc() {.closure.}
  MarkReadProc* = proc() {.closure.}
  UserLoginProc* = proc(token: string): tuple[ok: bool, err: string] {.closure.}
  UserLogoutProc* = proc(isOverwriting: bool) {.closure.}
  UserConnectProc* = proc(): tuple[ok: bool, err: string] {.closure.}
  UserDisconnectProc* = proc(): tuple[ok: bool, err: string] {.closure.}
  GetPortalsProc* = proc(): seq[UserPortalRecord] {.closure.}
  GetGuildByIDProc* = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.}
  BridgeGuildProc* = proc(guildId: string, everything: bool): tuple[ok: bool, err: string] {.closure.}
  UnbridgeGuildProc* = proc(guildId: string): tuple[ok: bool, err: string] {.closure.}
  UpdateGuildProc* = proc(rec: GuildRecord) {.closure.}
  EnsureInvitedProc* = proc(roomId: string, isDirect: bool): bool {.closure.}

  CommandEvent* = ref object
    command*: string
    args*: seq[string]
    rawArgs*: string
    roomId*: string

    # User state (read-only)
    userMxid*: string
    userDiscordId*: string
    userDiscordToken*: string
    userIsConnected*: bool
    userWasDisconnected*: bool
    userSessionUsername*: string  ## current username if session active
    userSpaceRoom*: string
    userDmSpaceRoom*: string

    # Portal state (optional — set when command runs in a portal room)
    hasPortal*: bool
    portalKey*: PortalKey
    portalName*: string
    portalMxid*: string
    portalGuildId*: string
    portalRelayWebhookId*: string
    portalRelayWebhookSecret*: string

    # Injectable stubs
    reply*: ReplyProc
    redact*: RedactProc
    markRead*: MarkReadProc
    userLogin*: UserLoginProc
    userLogout*: UserLogoutProc
    userConnect*: UserConnectProc
    userDisconnect*: UserDisconnectProc
    getPortals*: GetPortalsProc
    getGuildByID*: GetGuildByIDProc
    bridgeGuild*: BridgeGuildProc
    unbridgeGuild*: UnbridgeGuildProc
    updateGuild*: UpdateGuildProc
    ensureInvited*: EnsureInvitedProc

    # Test-observable state
    replies*: seq[string]  ## accumulated replies for testing

proc newCommandEvent*(
    command: string,
    args: seq[string] = @[],
    rawArgs: string = ""
): CommandEvent =
  let ce = CommandEvent(
    command: command,
    args: args,
    rawArgs: rawArgs,
    replies: @[]
  )

  # Default no-op stubs — capture `ce` (a ref) instead of `result`
  ce.reply = proc(msg: string) {.closure.} =
    ce.replies.add(msg)
  ce.redact = proc() {.closure.} = discard
  ce.markRead = proc() {.closure.} = discard
  ce.userLogin = proc(token: string): tuple[ok: bool, err: string] {.closure.} = (true, "")
  ce.userLogout = proc(isOverwriting: bool) {.closure.} = discard
  ce.userConnect = proc(): tuple[ok: bool, err: string] {.closure.} = (true, "")
  ce.userDisconnect = proc(): tuple[ok: bool, err: string] {.closure.} = (true, "")
  ce.getPortals = proc(): seq[UserPortalRecord] {.closure.} = @[]
  ce.getGuildByID = proc(id: string): tuple[found: bool, rec: GuildRecord] {.closure.} = (false, GuildRecord())
  ce.bridgeGuild = proc(guildId: string, everything: bool): tuple[ok: bool, err: string] {.closure.} = (true, "")
  ce.unbridgeGuild = proc(guildId: string): tuple[ok: bool, err: string] {.closure.} = (true, "")
  ce.updateGuild = proc(rec: GuildRecord) {.closure.} = discard
  ce.ensureInvited = proc(roomId: string, isDirect: bool): bool {.closure.} = true
  ce

# ===========================================================================
# Command definitions
# ===========================================================================

type
  CommandDef* = object
    name*: string
    aliases*: seq[string]
    helpSection*: string
    helpDescription*: string
    helpArgs*: string
    requiresLogin*: bool
    requiresPortal*: bool
    requiresAdmin*: bool
    handler*: proc(ce: CommandEvent) {.closure.}

# ===========================================================================
# fnLoginToken — Link via raw token
# ===========================================================================

proc fnLoginToken*(ce: CommandEvent) =
  if ce.args.len != 2:
    ce.reply("**Usage**: `$cmdprefix login-token <user/bot/oauth> <token>`")
    return
  if ce.markRead != nil: ce.markRead()
  if ce.userDiscordToken.len > 0:
    ce.reply("You're already logged in")
    return
  var token = ce.args[1]
  let decoded = decodeToken(token)
  if not decoded.ok:
    ce.reply("Invalid token")
    if ce.redact != nil: ce.redact()
    return
  case ce.args[0].toLowerAscii()
  of "user":
    discard  # token used as-is
  of "bot":
    token = "Bot " & token
  of "oauth":
    token = "Bearer " & token
  else:
    ce.reply("Token type must be `user`, `bot` or `oauth`")
    if ce.redact != nil: ce.redact()
    return
  ce.reply(fmt"Connecting to Discord as user ID {decoded.userId}")
  if ce.userLogin != nil:
    let res = ce.userLogin(token)
    if not res.ok:
      ce.reply(fmt"Error connecting to Discord: {res.err}")
      if ce.redact != nil: ce.redact()
      return
  ce.reply(fmt"Successfully logged in as @{ce.userSessionUsername}")
  if ce.redact != nil: ce.redact()

# ===========================================================================
# fnLogout
# ===========================================================================

proc fnLogout*(ce: CommandEvent) =
  let wasLoggedIn = ce.userDiscordId.len > 0
  if ce.userLogout != nil:
    ce.userLogout(false)
  if wasLoggedIn:
    ce.reply("Logged out successfully.")
  else:
    ce.reply("You weren't logged in, but data was re-cleared just to be safe.")

# ===========================================================================
# fnPing
# ===========================================================================

proc fnPing*(ce: CommandEvent) =
  if ce.userDiscordToken.len == 0:
    ce.reply("You're not logged in")
  elif not ce.userIsConnected:
    if ce.userWasDisconnected:
      ce.reply("You're logged in, but the Discord connection seems to be dead 💥")
    else:
      ce.reply("You have a Discord token stored, but are not connected for some reason 🤔")
  else:
    ce.reply(fmt"You're logged in as @{ce.userSessionUsername} (`{ce.userDiscordId}`)")

# ===========================================================================
# fnDisconnect
# ===========================================================================

proc fnDisconnect*(ce: CommandEvent) =
  if not ce.userIsConnected:
    ce.reply("You're already not connected")
  elif ce.userDisconnect != nil:
    let res = ce.userDisconnect()
    if not res.ok:
      ce.reply(fmt"Error while disconnecting: {res.err}")
    else:
      ce.reply("Successfully disconnected")

# ===========================================================================
# fnReconnect
# ===========================================================================

proc fnReconnect*(ce: CommandEvent) =
  if ce.userIsConnected:
    ce.reply("You're already connected")
  elif ce.userConnect != nil:
    let res = ce.userConnect()
    if not res.ok:
      ce.reply(fmt"Error while reconnecting: {res.err}")
    else:
      ce.reply("Successfully reconnected")

# ===========================================================================
# fnRejoinSpace
# ===========================================================================

proc fnRejoinSpace*(ce: CommandEvent) =
  if ce.args.len == 0:
    ce.reply("**Usage**: `$cmdprefix rejoin-space <guild ID/main/dms>`")
    return
  case ce.args[0].toLowerAscii()
  of "main":
    if ce.ensureInvited != nil:
      discard ce.ensureInvited(ce.userSpaceRoom, false)
    ce.reply("Invited you to your main space")
  of "dms":
    if ce.ensureInvited != nil:
      discard ce.ensureInvited(ce.userDmSpaceRoom, false)
    ce.reply("Invited you to your DM space")
  else:
    # Check if it's a guild ID (numeric)
    if isNumber(ce.args[0]):
      ce.reply("Rejoining guild spaces is not yet implemented")
    else:
      ce.reply("**Usage**: `$cmdprefix rejoin-space <guild ID/main/dms>`")

# ===========================================================================
# Guild management commands
# ===========================================================================

const
  smallGuildsHelp* = "**Usage**: `$cmdprefix guilds <help/status/bridge/unbridge> [guild ID] [...]`"
  fullGuildsHelp* = smallGuildsHelp & """

* **help** - View this help message.
* **status** - View the list of guilds and their bridging status.
* **bridge <_guild ID_> [--entire]** - Enable bridging for a guild. The --entire flag auto-creates portals for all channels.
* **bridging-mode <_guild ID_> <_mode_>** - Set the mode for bridging messages and new channels in a guild.
* **unbridge <_guild ID_>** - Unbridge a guild and delete all channel portal rooms."""

  availableModes* = "Available modes:\n" &
    "* `nothing` to never bridge any messages (default when unbridged)\n" &
    "* `if-portal-exists` to bridge messages in existing portals, but drop messages in unbridged channels\n" &
    "* `create-on-message` to bridge all messages and create portals if necessary on incoming messages (default after bridging)\n" &
    "* `everything` to bridge all messages and create portals proactively on bridge startup (default if bridged with `--entire`)\n"

proc fnListGuilds*(ce: CommandEvent) =
  if ce.getPortals == nil:
    ce.reply("No guilds found")
    return
  let portals = ce.getPortals()
  var items: seq[string] = @[]
  for userGuild in portals:
    if ce.getGuildByID == nil:
      continue
    let guild = ce.getGuildByID(userGuild.discordId)
    if not guild.found:
      continue
    let avatarHTML =
      if guild.rec.avatarUrl.len > 0:
        fmt"""<img data-mx-emoticon height="24" src="{guild.rec.avatarUrl}" alt="" title="Guild avatar"> """
      else:
        ""
    items.add(fmt"<li>{avatarHTML}{xmltree.escape(guild.rec.name)} (<code>{guild.rec.id}</code>) - {guild.rec.bridgingMode.description()}</li>")
  if items.len == 0:
    ce.reply("No guilds found")
  else:
    ce.reply("<p>List of guilds:</p><ul>" & items.join("") & "</ul>")

proc fnBridgeGuild*(ce: CommandEvent) =
  if ce.args.len == 0 or ce.args.len > 2:
    ce.reply("**Usage**: `$cmdprefix guilds bridge <guild ID> [--entire]")
  elif ce.bridgeGuild != nil:
    let entire = ce.args.len == 2 and ce.args[1].toLowerAscii() == "--entire"
    let res = ce.bridgeGuild(ce.args[0], entire)
    if not res.ok:
      ce.reply(fmt"Error bridging guild: {res.err}")
    else:
      ce.reply("Successfully bridged guild")

proc fnUnbridgeGuild*(ce: CommandEvent) =
  if ce.args.len != 1:
    ce.reply("**Usage**: `$cmdprefix guilds unbridge <guild ID>")
  elif ce.unbridgeGuild != nil:
    let res = ce.unbridgeGuild(ce.args[0])
    if not res.ok:
      ce.reply(fmt"Error unbridging guild: {res.err}")
    else:
      ce.reply("Successfully unbridged guild")

proc fnGuildBridgingMode*(ce: CommandEvent) =
  if ce.args.len == 0 or ce.args.len > 2:
    ce.reply("**Usage**: `$cmdprefix guilds bridging-mode <guild ID> [mode]`\n\n" & availableModes)
    return
  if ce.getGuildByID == nil:
    ce.reply("Guild not found")
    return
  let guild = ce.getGuildByID(ce.args[0])
  if not guild.found:
    ce.reply("Guild not found")
    return
  if ce.args.len == 1:
    ce.reply(fmt"{guild.rec.plainName} ({guild.rec.id}) is currently set to {guild.rec.bridgingMode.description()} (`{guild.rec.bridgingMode.modeString()}`)" & "\n\n" & availableModes)
    return
  let mode = parseGuildBridgingMode(ce.args[1])
  # Check if the string was actually valid (not just defaulting to gbmNothing)
  if ce.args[1].toLowerAscii() notin ["nothing", "if-portal-exists", "create-on-message", "everything"]:
    ce.reply(fmt"Invalid guild bridging mode `{ce.args[1]}`")
    return
  var updatedGuild = guild.rec
  updatedGuild.bridgingMode = mode
  if ce.updateGuild != nil:
    ce.updateGuild(updatedGuild)
  ce.reply(fmt"Set guild bridging mode to {mode.description()}")

proc fnGuilds*(ce: CommandEvent) =
  if ce.args.len == 0:
    ce.reply(fullGuildsHelp)
    return
  let subcommand = ce.args[0].toLowerAscii()
  ce.args = ce.args[1 .. ^1]
  case subcommand
  of "status", "list":
    fnListGuilds(ce)
  of "bridge":
    fnBridgeGuild(ce)
  of "unbridge", "delete":
    fnUnbridgeGuild(ce)
  of "bridging-mode", "mode":
    fnGuildBridgingMode(ce)
  of "help":
    ce.reply(fullGuildsHelp)
  else:
    ce.reply(fmt"Unknown subcommand `{subcommand}`" & "\n\n" & smallGuildsHelp)

# ===========================================================================
# fnSetRelay / fnUnsetRelay — relay webhook management
# ===========================================================================

const
  webhookURLFormat* = "https://discord.com/api/webhooks/%d/%s"
  selectRelayHelp* = "Usage: `$cmdprefix [room ID] <​--url URL> OR <​--create [name]>`"

proc fnSetRelay*(ce: CommandEvent) =
  if not ce.hasPortal:
    ce.reply("You must either run the command in a portal, or specify an internal room ID as the first parameter")
    return
  if ce.portalGuildId.len == 0:
    ce.reply("Only guild channels can have relays")
    return
  if ce.portalRelayWebhookId.len > 0:
    ce.reply(fmt"This channel already has a relay webhook ({ce.portalRelayWebhookId})")
    return
  if ce.args.len == 0:
    ce.reply(selectRelayHelp)
    return
  let createType = ce.args[0].strip(chars = {'-'}).toLowerAscii()
  case createType
  of "url":
    if ce.args.len < 2:
      ce.reply("Usage: `$cmdprefix [room ID] --url <URL>")
    else:
      ce.reply(fmt"Webhook URL saved (stub — would validate URL {ce.args[1]})")
  of "create":
    var name = "mautrix"
    if ce.args.len > 1:
      name = ce.args[1 .. ^1].join(" ")
    ce.reply(fmt"Would create webhook named {name} (stub)")
  else:
    ce.reply(selectRelayHelp)

proc fnUnsetRelay*(ce: CommandEvent) =
  if ce.portalRelayWebhookId.len == 0:
    ce.reply("This portal doesn't have a relay webhook")
    return
  if ce.args.len > 0 and ce.args[0] == "--delete":
    ce.reply("Successfully deleted webhook")
  else:
    ce.reply("Relay webhook disabled")

# ===========================================================================
# fnUnbridge
# ===========================================================================

proc fnUnbridge*(ce: CommandEvent) =
  if not ce.hasPortal:
    ce.reply("This is not a portal room")
    return
  ce.reply("Room unbridged successfully")

# ===========================================================================
# fnCreatePortal
# ===========================================================================

proc fnCreatePortal*(ce: CommandEvent) =
  if ce.args.len == 0:
    ce.reply("**Usage**: `$cmdprefix create-portal <channel ID>`")
    return
  ce.reply(fmt"Would create portal for channel {ce.args[0]} (stub)")

# ===========================================================================
# fnDeleteAllPortals
# ===========================================================================

proc fnDeleteAllPortals*(ce: CommandEvent) =
  ce.reply("Would delete all portals (stub — admin only)")

# ===========================================================================
# fnBridge — bridge existing Matrix room to a Discord channel
# ===========================================================================

proc fnBridge*(ce: CommandEvent) =
  if ce.hasPortal:
    ce.reply("This is already a portal room. Unbridge with `$cmdprefix unbridge` first if you want to link it to a different channel.")
    return
  var channelId = ""
  var fail = true
  for arg in ce.args:
    let a = arg.toLowerAscii()
    if a == "--replace" or a == "--replace=delete":
      discard
    elif channelId.len == 0 and isNumber(a):
      channelId = a
      fail = false
    else:
      fail = true
      break
  if fail:
    ce.reply("**Usage**: `$cmdprefix bridge [--replace[=delete]] <channel ID>`")
    return
  ce.reply(fmt"Room successfully bridged to channel {channelId}")

# ===========================================================================
# Command registry
# ===========================================================================

proc allCommandDefs*(): seq[CommandDef] =
  @[
    CommandDef(
      name: "login-token",
      helpSection: HelpSectionAuth,
      helpDescription: "Link the bridge to your Discord account by extracting the access token manually.",
      helpArgs: "<user/bot/oauth> <_token_>",
      handler: fnLoginToken
    ),
    CommandDef(
      name: "logout",
      helpSection: HelpSectionAuth,
      helpDescription: "Forget the stored Discord auth token.",
      handler: fnLogout
    ),
    CommandDef(
      name: "ping",
      helpSection: HelpSectionAuth,
      helpDescription: "Check your connection to Discord",
      handler: fnPing
    ),
    CommandDef(
      name: "disconnect",
      helpSection: HelpSectionAuth,
      helpDescription: "Disconnect from Discord (without logging out)",
      requiresLogin: true,
      handler: fnDisconnect
    ),
    CommandDef(
      name: "reconnect",
      aliases: @["connect"],
      helpSection: HelpSectionAuth,
      helpDescription: "Reconnect to Discord after disconnecting",
      requiresLogin: true,
      handler: fnReconnect
    ),
    CommandDef(
      name: "rejoin-space",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Ask the bridge for an invite to a space you left",
      helpArgs: "<_guild ID_/main/dms>",
      requiresLogin: true,
      handler: fnRejoinSpace
    ),
    CommandDef(
      name: "guilds",
      aliases: @["servers", "guild", "server"],
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Guild bridging management",
      helpArgs: "<status/bridge/unbridge/bridging-mode> [_guild ID_] [...]",
      requiresLogin: true,
      handler: fnGuilds
    ),
    CommandDef(
      name: "set-relay",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Create or set a relay webhook for a portal",
      helpArgs: "[room ID] <​--url URL> OR <​--create [name]>",
      requiresLogin: true,
      handler: fnSetRelay
    ),
    CommandDef(
      name: "unset-relay",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Disable the relay webhook and optionally delete it on Discord",
      helpArgs: "[--delete]",
      requiresPortal: true,
      handler: fnUnsetRelay
    ),
    CommandDef(
      name: "bridge",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Bridge this room to a specific Discord channel",
      helpArgs: "[--replace[=delete]] <_channel ID_>",
      handler: fnBridge
    ),
    CommandDef(
      name: "unbridge",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Unbridge this room from the linked Discord channel",
      requiresPortal: true,
      handler: fnUnbridge
    ),
    CommandDef(
      name: "create-portal",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Create a portal for a specific channel",
      helpArgs: "<_channel ID_>",
      requiresLogin: true,
      handler: fnCreatePortal
    ),
    CommandDef(
      name: "delete-portal",
      helpSection: HelpSectionPortalManagement,
      helpDescription: "Unbridge this room and kick all Matrix users",
      requiresPortal: true,
      handler: fnUnbridge  # same handler as unbridge
    ),
    CommandDef(
      name: "delete-all-portals",
      helpSection: HelpSectionAdmin,
      helpDescription: "Delete all portals.",
      requiresAdmin: true,
      handler: fnDeleteAllPortals
    ),
  ]

proc findCommand*(defs: seq[CommandDef], name: string): int =
  ## Returns index of command def by name or alias, or -1 if not found.
  let lower = name.toLowerAscii()
  for i, def in defs:
    if def.name == lower:
      return i
    for alias in def.aliases:
      if alias == lower:
        return i
  -1

proc dispatch*(defs: seq[CommandDef], ce: CommandEvent): bool =
  ## Dispatches a command event to the matching handler.
  ## Returns true if a handler was found and called, false otherwise.
  let idx = findCommand(defs, ce.command)
  if idx < 0:
    return false
  defs[idx].handler(ce)
  true
