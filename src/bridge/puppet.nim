## Puppet helpers ported from puppet.go.
## Provides runtime Puppet wrapper around PuppetRecord for name, avatar,
## contact‐info updates and intent resolution.

import std/[strutils, json, re]
import config/config
import database/[entities, store]
import bridge/runtime

# ---------------------------------------------------------------------------
# Discord CDN endpoint helpers (mirrors discordgo constants)
# ---------------------------------------------------------------------------

const
  cdnBase = "https://cdn.discordapp.com"

proc endpointUserAvatar(userId, avatarId: string): string =
  cdnBase & "/avatars/" & userId & "/" & avatarId & ".png"

proc endpointUserAvatarAnimated(userId, avatarId: string): string =
  cdnBase & "/avatars/" & userId & "/" & avatarId & ".gif"

proc endpointGuildMemberAvatar(guildId, userId, avatarId: string): string =
  cdnBase & "/guilds/" & guildId & "/users/" & userId & "/avatars/" & avatarId & ".png"

proc endpointGuildMemberAvatarAnimated(guildId, userId, avatarId: string): string =
  cdnBase & "/guilds/" & guildId & "/users/" & userId & "/avatars/" & avatarId & ".gif"

# ---------------------------------------------------------------------------
# Minimal DiscordUser type for UpdateInfo/UpdateName/UpdateAvatar arguments
# (mirrors the fields accessed on discordgo.User in puppet.go)
# ---------------------------------------------------------------------------

type
  DiscordUser* = object
    id*: string
    username*: string
    discriminator*: string
    globalName*: string
    avatar*: string
    bot*: bool

  DiscordMessage* = object
    id*: string
    webhookId*: string
    applicationId*: string

# ---------------------------------------------------------------------------
# Intent stubs — thin wrappers for Matrix appservice calls.
# Real implementations will call the homeserver; these provide the same API
# surface that puppet.go relies on so callers compile and test cleanly.
# ---------------------------------------------------------------------------

type
  IntentAPI* = ref object
    mxid*: string

  SetDisplayNameResult* = tuple[ok: bool, err: string]
  SetAvatarURLResult*   = tuple[ok: bool, err: string]
  EnsureRegisteredResult* = tuple[ok: bool, err: string]
  BeeperUpdateProfileResult* = tuple[ok: bool, err: string]

# Stub implementations: callers can replace these via the proc-type fields
# on PuppetContext when they wire up actual Matrix HTTP calls.

type
  SetDisplayNameProc*     = proc(mxid, name: string): SetDisplayNameResult {.closure.}
  SetAvatarURLProc*       = proc(mxid, url: string): SetAvatarURLResult {.closure.}
  EnsureRegisteredProc*   = proc(mxid: string): EnsureRegisteredResult {.closure.}
  BeeperUpdateProfileProc* = proc(mxid: string, info: JsonNode): BeeperUpdateProfileResult {.closure.}

  ## Callback for copyAttachmentToMatrix (lives in attachments module).
  CopyAttachmentResult* = object
    ok*: bool
    mxc*: string
    err*: string

  CopyAttachmentProc* = proc(mxid, url: string, encrypt: bool, attachmentId: string): CopyAttachmentResult {.closure.}

  ## Callback to look up DM portal avatar MXC via directmedia API.
  AvatarMXCProc* = proc(guildId, userId, avatarId: string): string {.closure.}

  ## Callback for fetching Discord user info through a source user's session.
  FetchUserProc* = proc(discordUserId: string): tuple[ok: bool, user: DiscordUser] {.closure.}

  ## Callback to iterate DM portals and apply a meta‐update.
  ## The callback receives a portal key and should perform any portal updates.
  GetDMPortalsProc* = proc(puppetId: string): seq[PortalKey] {.closure.}

# ---------------------------------------------------------------------------
# PuppetContext — wiring object that carries all external dependencies
# ---------------------------------------------------------------------------

type
  PuppetContext* = ref object
    runtime*: DiscordBridgeRuntime
    cfg*: Config

    ## Matrix client stubs (set by the bridge at startup)
    setDisplayName*: SetDisplayNameProc
    setAvatarURL*: SetAvatarURLProc
    ensureRegistered*: EnsureRegisteredProc
    beeperUpdateProfile*: BeeperUpdateProfileProc
    copyAttachment*: CopyAttachmentProc
    avatarMXC*: AvatarMXCProc
    fetchUser*: FetchUserProc
    getDMPortals*: GetDMPortalsProc

    ## Beeper spec feature flags
    supportsBeeperProfileMeta*: bool

    ## Bridge identity (for contact info)
    beeperServiceName*: string
    beeperNetworkName*: string

    ## Compiled puppet MXID regex (lazily initialised)
    puppetMXIDRegex: Regex
    regexInitialised: bool

# ---------------------------------------------------------------------------
# Default no‐op stubs
# ---------------------------------------------------------------------------

proc defaultSetDisplayName(mxid, name: string): SetDisplayNameResult =
  (true, "")

proc defaultSetAvatarURL(mxid, url: string): SetAvatarURLResult =
  (true, "")

proc defaultEnsureRegistered(mxid: string): EnsureRegisteredResult =
  (true, "")

proc defaultBeeperUpdateProfile(mxid: string, info: JsonNode): BeeperUpdateProfileResult =
  (true, "")

proc defaultCopyAttachment(mxid, url: string, encrypt: bool, attachmentId: string): CopyAttachmentResult =
  CopyAttachmentResult(ok: false, mxc: "", err: "copy attachment not configured")

proc defaultAvatarMXC(guildId, userId, avatarId: string): string =
  ""

proc defaultFetchUser(discordUserId: string): tuple[ok: bool, user: DiscordUser] =
  (false, DiscordUser())

proc defaultGetDMPortals(puppetId: string): seq[PortalKey] =
  @[]

proc newPuppetContext*(runtime: DiscordBridgeRuntime, cfg: Config): PuppetContext =
  new(result)
  result.runtime = runtime
  result.cfg = cfg
  result.setDisplayName = defaultSetDisplayName
  result.setAvatarURL = defaultSetAvatarURL
  result.ensureRegistered = defaultEnsureRegistered
  result.beeperUpdateProfile = defaultBeeperUpdateProfile
  result.copyAttachment = defaultCopyAttachment
  result.avatarMXC = defaultAvatarMXC
  result.fetchUser = defaultFetchUser
  result.getDMPortals = defaultGetDMPortals
  result.supportsBeeperProfileMeta = false
  result.beeperServiceName = "discordgo"
  result.beeperNetworkName = "discord"
  result.regexInitialised = false

# ---------------------------------------------------------------------------
# FormatPuppetMXID — mirrors br.FormatPuppetMXID
# ---------------------------------------------------------------------------

proc formatPuppetMXID*(ctx: PuppetContext, discordId: string): string =
  ## Returns a full Matrix user ID for the given Discord user ID,
  ## e.g. "@discord_123456:example.com".
  let localpart = ctx.cfg.bridge.formatUsername(discordId)
  "@" & localpart & ":" & ctx.cfg.homeserver.domain

# ---------------------------------------------------------------------------
# GetMXID / GetDisplayname / GetAvatarURL — simple accessors
# ---------------------------------------------------------------------------

proc getMXID*(ctx: PuppetContext, rec: PuppetRecord): string =
  ctx.formatPuppetMXID(rec.id)

proc getDisplayname*(rec: PuppetRecord): string =
  rec.name

proc getAvatarURL*(rec: PuppetRecord): string =
  rec.avatarUrl

# ---------------------------------------------------------------------------
# DefaultIntent / IntentFor / CustomIntent
# ---------------------------------------------------------------------------

proc defaultIntent*(ctx: PuppetContext, rec: PuppetRecord): IntentAPI =
  IntentAPI(mxid: ctx.formatPuppetMXID(rec.id))

proc intentFor*(ctx: PuppetContext, rec: PuppetRecord, portalReceiver: string): IntentAPI =
  ## Returns the custom intent if the puppet has one AND this isn't a
  ## receiver‐scoped portal belonging to another user, else default intent.
  ## Note: customIntent is currently always nil until custom puppet support
  ## wires up actual Matrix login; this mirrors the Go baseline logic.
  if portalReceiver.len > 0 and portalReceiver != rec.id:
    return ctx.defaultIntent(rec)
  ctx.defaultIntent(rec)

proc customIntent*(rec: PuppetRecord): IntentAPI =
  ## Placeholder — custom intents not yet supported at runtime.
  nil

# ---------------------------------------------------------------------------
# ParsePuppetMXID — mirrors br.ParsePuppetMXID
# ---------------------------------------------------------------------------

proc parsePuppetMXID*(ctx: PuppetContext, mxid: string): tuple[discordId: string, ok: bool] =
  if not ctx.regexInitialised:
    let pattern = "^@" & ctx.cfg.bridge.formatUsername("([0-9]+)") & ":" &
                  ctx.cfg.homeserver.domain.replace(".", "\\.") & "$"
    ctx.puppetMXIDRegex = re(pattern)
    ctx.regexInitialised = true

  var matches: array[1, string] = [""] 
  if match(mxid, ctx.puppetMXIDRegex, matches):
    return (matches[0], true)
  ("", false)

# ---------------------------------------------------------------------------
# GetPuppetByMXID / GetPuppetByID / GetPuppetByCustomMXID / GetAll*
# These delegate to the PuppetManager in the runtime.
# ---------------------------------------------------------------------------

proc getPuppetByMXID*(ctx: PuppetContext, mxid: string): tuple[found: bool, rec: PuppetRecord] =
  let parsed = ctx.parsePuppetMXID(mxid)
  if not parsed.ok:
    return (false, default(PuppetRecord))
  ctx.runtime.puppets.getByID(parsed.discordId, createIfMissing = true)

proc getPuppetByID*(ctx: PuppetContext, id: string): tuple[found: bool, rec: PuppetRecord] =
  ctx.runtime.puppets.getByID(id, createIfMissing = true)

proc getPuppetByCustomMXID*(ctx: PuppetContext, mxid: string): tuple[found: bool, rec: PuppetRecord] =
  ctx.runtime.puppets.getByCustomMXID(mxid)

proc getAllPuppetsWithCustomMXID*(ctx: PuppetContext): seq[PuppetRecord] =
  ctx.runtime.puppets.db.getAllPuppetsWithCustomMXID()

proc getAllPuppets*(ctx: PuppetContext): seq[PuppetRecord] =
  ctx.runtime.puppets.db.getAllPuppets()

# ---------------------------------------------------------------------------
# reuploadUserAvatar — mirrors br.reuploadUserAvatar
# ---------------------------------------------------------------------------

proc reuploadUserAvatar*(
    ctx: PuppetContext,
    intentMxid: string,
    guildId, userId, avatarId: string
): tuple[mxc: string, downloadURL: string, err: string] =
  var downloadURL: string
  if guildId.len == 0:
    if avatarId.startsWith("a_"):
      downloadURL = endpointUserAvatarAnimated(userId, avatarId)
    else:
      downloadURL = endpointUserAvatar(userId, avatarId)
  else:
    if avatarId.startsWith("a_"):
      downloadURL = endpointGuildMemberAvatarAnimated(guildId, userId, avatarId)
    else:
      downloadURL = endpointGuildMemberAvatar(guildId, userId, avatarId)

  # Try direct media first
  let directMxc = ctx.avatarMXC(guildId, userId, avatarId)
  if directMxc.len > 0:
    return (directMxc, downloadURL, "")

  let attachmentId = "avatar/" & guildId & "/" & userId & "/" & avatarId
  let copied = ctx.copyAttachment(intentMxid, downloadURL, false, attachmentId)
  if not copied.ok:
    return ("", downloadURL, copied.err)
  (copied.mxc, downloadURL, "")

# ---------------------------------------------------------------------------
# UpdateName — mirrors puppet.UpdateName
# ---------------------------------------------------------------------------

proc updateName*(ctx: PuppetContext, rec: var PuppetRecord, info: DiscordUser): bool =
  let params = DisplaynameParams(
    globalName: info.globalName,
    username: info.username,
    discriminator: info.discriminator,
    webhook: rec.isWebhook,
    application: rec.isApplication,
    bot: info.bot
  )
  let newName = ctx.cfg.bridge.formatDisplayname(params)
  if rec.name == newName and rec.nameSet:
    return false

  rec.name = newName
  rec.nameSet = false
  let mxid = ctx.formatPuppetMXID(rec.id)
  let res = ctx.setDisplayName(mxid, newName)
  if not res.ok:
    discard  # logged at call site
  else:
    rec.nameSet = true
  true

# ---------------------------------------------------------------------------
# UpdateAvatar — mirrors puppet.UpdateAvatar
# ---------------------------------------------------------------------------

proc updateAvatar*(ctx: PuppetContext, rec: var PuppetRecord, info: DiscordUser): bool =
  var avatarId = info.avatar
  if rec.isWebhook and not ctx.cfg.bridge.enableWebhookAvatars:
    avatarId = ""

  if rec.avatar == avatarId and rec.avatarSet:
    return false

  let avatarChanged = avatarId != rec.avatar
  rec.avatar = avatarId
  rec.avatarSet = false
  rec.avatarUrl = ""

  if rec.avatar.len > 0 and (rec.avatarUrl.len == 0 or avatarChanged):
    let intentMxid = ctx.formatPuppetMXID(rec.id)
    let uploaded = ctx.reuploadUserAvatar(intentMxid, "", info.id, rec.avatar)
    if uploaded.err.len > 0:
      return true  # changed but failed to upload
    rec.avatarUrl = uploaded.mxc

  let mxid = ctx.formatPuppetMXID(rec.id)
  let res = ctx.setAvatarURL(mxid, rec.avatarUrl)
  if not res.ok:
    discard  # logged at call site
  else:
    rec.avatarSet = true
  true

# ---------------------------------------------------------------------------
# UpdateContactInfo — mirrors puppet.UpdateContactInfo
# ---------------------------------------------------------------------------

proc resendContactInfo*(ctx: PuppetContext, rec: var PuppetRecord) =
  if not ctx.supportsBeeperProfileMeta or rec.contactInfoSet:
    return

  var discordUsername = rec.username
  if rec.discriminator != "0":
    discordUsername &= "#" & rec.discriminator

  var identifiers: seq[string]
  if rec.isWebhook:
    identifiers = @[]
  else:
    identifiers = @["discord:" & discordUsername]

  let contactInfo = %*{
    "com.beeper.bridge.identifiers": identifiers,
    "com.beeper.bridge.remote_id": rec.id,
    "com.beeper.bridge.service": ctx.beeperServiceName,
    "com.beeper.bridge.network": ctx.beeperNetworkName,
    "com.beeper.bridge.is_network_bot": rec.isBot
  }

  let mxid = ctx.formatPuppetMXID(rec.id)
  let res = ctx.beeperUpdateProfile(mxid, contactInfo)
  if not res.ok:
    discard  # logged at call site
  else:
    rec.contactInfoSet = true

# ---------------------------------------------------------------------------
# UpdateContactInfo — mirrors puppet.UpdateContactInfo
# ---------------------------------------------------------------------------

proc updateContactInfo*(ctx: PuppetContext, rec: var PuppetRecord, info: DiscordUser): bool =
  var changed = false
  if rec.username != info.username:
    rec.username = info.username
    changed = true
  if rec.globalName != info.globalName:
    rec.globalName = info.globalName
    changed = true
  if rec.discriminator != info.discriminator:
    rec.discriminator = info.discriminator
    changed = true
  if rec.isBot != info.bot:
    rec.isBot = info.bot
    changed = true

  if (changed and not rec.isWebhook) or not rec.contactInfoSet:
    rec.contactInfoSet = false
    ctx.resendContactInfo(rec)
    return true
  false

# ---------------------------------------------------------------------------
# UpdateInfo — mirrors puppet.UpdateInfo
# (main entry point: fetches user if needed, updates name/avatar/contact)
# ---------------------------------------------------------------------------

proc updateInfo*(
    ctx: PuppetContext,
    rec: var PuppetRecord,
    info: var DiscordUser,
    message: DiscordMessage,
    hasSource: bool
): bool =
  ## Updates puppet name, avatar, and contact info from the given Discord user.
  ## Returns true if any field changed and the record should be persisted.
  ##
  ## If `info` has empty username/discriminator and the puppet has no name,
  ## attempts to fetch user info via `ctx.fetchUser`.

  if info.username.len == 0 or info.discriminator.len == 0:
    if rec.name.len > 0 or not hasSource:
      return false
    let fetched = ctx.fetchUser(rec.id)
    if not fetched.ok:
      return false
    info = fetched.user

  let mxid = ctx.formatPuppetMXID(rec.id)
  discard ctx.ensureRegistered(mxid)

  var changed = false

  # Mark webhook/application from message metadata
  if message.id.len > 0:
    if message.webhookId.len > 0 and message.applicationId.len == 0 and not rec.isWebhook:
      rec.isWebhook = true
      changed = true
    if message.applicationId.len > 0 and not rec.isApplication:
      rec.isApplication = true
      rec.isWebhook = false
      changed = true

  changed = ctx.updateContactInfo(rec, info) or changed
  changed = ctx.updateName(rec, info) or changed
  changed = ctx.updateAvatar(rec, info) or changed

  if changed:
    ctx.runtime.puppets.upsert(rec)
  changed
