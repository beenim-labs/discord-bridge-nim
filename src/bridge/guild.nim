## Guild helpers ported from guildportal.go.
## Provides runtime Guild operations: bridge info, room creation, name/avatar
## update, cleanup, and deletion — operating on GuildRecord via GuildManager.

import std/[strutils, json]
import config/config
import database/[entities, store]
import bridge/runtime

# ---------------------------------------------------------------------------
# Discord CDN endpoint helper (mirrors discordgo.EndpointGuildIcon)
# ---------------------------------------------------------------------------

const cdnBase = "https://cdn.discordapp.com"

proc endpointGuildIcon(guildId, iconHash: string): string =
  cdnBase & "/icons/" & guildId & "/" & iconHash & ".png"

# ---------------------------------------------------------------------------
# Minimal DiscordGuild metadata for UpdateInfo/CreateMatrixRoom
# (mirrors the fields accessed on discordgo.Guild in guildportal.go)
# ---------------------------------------------------------------------------

type
  DiscordGuildMeta* = object
    id*: string
    name*: string
    icon*: string
    unavailable*: bool

# ---------------------------------------------------------------------------
# Matrix client stub types
# ---------------------------------------------------------------------------

type
  SendStateEventResult* = tuple[ok: bool, eventId: string, err: string]
  CreateRoomResult*     = tuple[ok: bool, roomId: string, err: string]
  SetRoomNameResult*    = tuple[ok: bool, err: string]
  SetRoomAvatarResult*  = tuple[ok: bool, err: string]
  DeleteRoomResult*     = tuple[ok: bool, err: string]
  CleanupRoomResult*    = tuple[ok: bool, err: string]
  EnsureInvitedResult*  = tuple[ok: bool, err: string]

  SendStateEventProc*   = proc(roomId, eventType, stateKey: string, content: JsonNode): SendStateEventResult {.closure.}
  CreateRoomProc*       = proc(req: JsonNode): CreateRoomResult {.closure.}
  SetRoomNameProc*      = proc(roomId, name: string): SetRoomNameResult {.closure.}
  SetRoomAvatarProc*    = proc(roomId, avatarUrl: string): SetRoomAvatarResult {.closure.}
  DeleteRoomProc*       = proc(roomId: string): DeleteRoomResult {.closure.}
  CleanupRoomProc*      = proc(roomId: string): CleanupRoomResult {.closure.}
  EnsureInvitedProc*    = proc(roomId, userId: string): EnsureInvitedResult {.closure.}

  ## Callback for avatar upload (reuses CopyAttachmentResult from puppet module).
  GuildCopyAttachmentResult* = object
    ok*: bool
    mxc*: string
    err*: string

  GuildCopyAttachmentProc* = proc(url: string, encrypt: bool, attachmentId: string): GuildCopyAttachmentResult {.closure.}

# ---------------------------------------------------------------------------
# GuildContext — wiring object that carries all external dependencies
# ---------------------------------------------------------------------------

type
  GuildContext* = ref object
    runtime*: DiscordBridgeRuntime
    cfg*: Config

    ## Matrix client stubs
    sendStateEvent*: SendStateEventProc
    createRoom*: CreateRoomProc
    setRoomName*: SetRoomNameProc
    setRoomAvatar*: SetRoomAvatarProc
    deleteRoom*: DeleteRoomProc
    cleanupRoom*: CleanupRoomProc
    ensureInvited*: EnsureInvitedProc
    copyAttachment*: GuildCopyAttachmentProc

    ## Beeper feature flags
    supportsBeeperRoomYeeting*: bool

    ## Bot identity
    botUserID*: string
    botAvatarUrl*: string

# ---------------------------------------------------------------------------
# Default no-op stubs
# ---------------------------------------------------------------------------

proc defaultSendStateEvent(roomId, eventType, stateKey: string, content: JsonNode): SendStateEventResult =
  (true, "", "")

proc defaultCreateRoom(req: JsonNode): CreateRoomResult =
  (false, "", "createRoom not configured")

proc defaultSetRoomName(roomId, name: string): SetRoomNameResult =
  (true, "")

proc defaultSetRoomAvatar(roomId, avatarUrl: string): SetRoomAvatarResult =
  (true, "")

proc defaultDeleteRoom(roomId: string): DeleteRoomResult =
  (true, "")

proc defaultCleanupRoom(roomId: string): CleanupRoomResult =
  (true, "")

proc defaultEnsureInvited(roomId, userId: string): EnsureInvitedResult =
  (true, "")

proc defaultGuildCopyAttachment(url: string, encrypt: bool, attachmentId: string): GuildCopyAttachmentResult =
  GuildCopyAttachmentResult(ok: false, mxc: "", err: "copy attachment not configured")

proc newGuildContext*(runtime: DiscordBridgeRuntime, cfg: Config): GuildContext =
  new(result)
  result.runtime = runtime
  result.cfg = cfg
  result.sendStateEvent = defaultSendStateEvent
  result.createRoom = defaultCreateRoom
  result.setRoomName = defaultSetRoomName
  result.setRoomAvatar = defaultSetRoomAvatar
  result.deleteRoom = defaultDeleteRoom
  result.cleanupRoom = defaultCleanupRoom
  result.ensureInvited = defaultEnsureInvited
  result.copyAttachment = defaultGuildCopyAttachment
  result.supportsBeeperRoomYeeting = false
  result.botUserID = ""
  result.botAvatarUrl = ""

# ---------------------------------------------------------------------------
# GetGuildByMXID / GetGuildByID / GetAllGuilds — delegate to manager
# ---------------------------------------------------------------------------

proc getGuildByMXID*(ctx: GuildContext, mxid: string): tuple[found: bool, rec: GuildRecord] =
  ctx.runtime.guilds.getByMXID(mxid)

proc getGuildByID*(ctx: GuildContext, id: string, createIfMissing = false): tuple[found: bool, rec: GuildRecord] =
  ctx.runtime.guilds.getByID(id, createIfMissing)

proc getAllGuilds*(ctx: GuildContext): seq[GuildRecord] =
  ctx.runtime.guilds.db.getAllGuilds()

# ---------------------------------------------------------------------------
# getBridgeInfo — mirrors guild.getBridgeInfo
# ---------------------------------------------------------------------------

proc getBridgeInfo*(ctx: GuildContext, rec: GuildRecord): tuple[stateKey: string, content: JsonNode] =
  let bridgeInfo = %*{
    "bridgebot": ctx.botUserID,
    "creator": ctx.botUserID,
    "protocol": {
      "id": "discordgo",
      "displayname": "Discord",
      "avatar_url": ctx.botAvatarUrl,
      "external_url": "https://discord.com/"
    },
    "channel": {
      "id": rec.id,
      "displayname": rec.name,
      "avatar_url": rec.avatarUrl
    }
  }
  let stateKey = "fi.mau.discord://discord/" & rec.id
  (stateKey, bridgeInfo)

# ---------------------------------------------------------------------------
# UpdateBridgeInfo — mirrors guild.UpdateBridgeInfo
# ---------------------------------------------------------------------------

proc updateBridgeInfo*(ctx: GuildContext, rec: GuildRecord) =
  if rec.mxid.len == 0:
    return
  let (stateKey, content) = ctx.getBridgeInfo(rec)
  discard ctx.sendStateEvent(rec.mxid, "m.bridge", stateKey, content)
  # TODO remove once https://github.com/matrix-org/matrix-doc/pull/2346 is in spec
  discard ctx.sendStateEvent(rec.mxid, "uk.half-shot.bridge", stateKey, content)

# ---------------------------------------------------------------------------
# UpdateName — mirrors guild.UpdateName
# ---------------------------------------------------------------------------

proc updateName*(ctx: GuildContext, rec: var GuildRecord, meta: DiscordGuildMeta): bool =
  let name = ctx.cfg.bridge.formatGuildName(GuildNameParams(name: meta.name))
  if rec.plainName == meta.name and rec.name == name and (rec.nameSet or rec.mxid.len == 0):
    return false

  rec.name = name
  rec.plainName = meta.name
  rec.nameSet = false
  if rec.mxid.len > 0:
    let res = ctx.setRoomName(rec.mxid, rec.name)
    if res.ok:
      rec.nameSet = true
  true

# ---------------------------------------------------------------------------
# UpdateAvatar — mirrors guild.UpdateAvatar
# ---------------------------------------------------------------------------

proc updateAvatar*(ctx: GuildContext, rec: var GuildRecord, iconID: string): bool =
  if rec.avatar == iconID and
     (iconID.len == 0) == (rec.avatarUrl.len == 0) and
     (rec.avatarSet or rec.mxid.len == 0):
    return false

  rec.avatarSet = false
  rec.avatar = iconID
  rec.avatarUrl = ""
  if rec.avatar.len > 0:
    let attachmentId = "guild_avatar/" & rec.id & "/" & iconID
    let copied = ctx.copyAttachment(endpointGuildIcon(rec.id, iconID), false, attachmentId)
    if not copied.ok:
      return true  # changed but upload failed
    rec.avatarUrl = copied.mxc
  if rec.mxid.len > 0:
    let res = ctx.setRoomAvatar(rec.mxid, rec.avatarUrl)
    if res.ok:
      rec.avatarSet = true
  true

# ---------------------------------------------------------------------------
# UpdateInfo — mirrors guild.UpdateInfo
# ---------------------------------------------------------------------------

proc updateInfo*(ctx: GuildContext, rec: var GuildRecord, meta: DiscordGuildMeta, sourceUserMxid = ""): bool =
  if meta.unavailable:
    return false

  var changed = false
  changed = ctx.updateName(rec, meta) or changed
  changed = ctx.updateAvatar(rec, meta.icon) or changed
  if changed:
    ctx.updateBridgeInfo(rec)
    ctx.runtime.guilds.upsert(rec)
  if sourceUserMxid.len > 0 and rec.mxid.len > 0:
    discard ctx.ensureInvited(rec.mxid, sourceUserMxid)
  changed

# ---------------------------------------------------------------------------
# CreateMatrixRoom — mirrors guild.CreateMatrixRoom
# ---------------------------------------------------------------------------

proc createMatrixRoom*(ctx: GuildContext, rec: var GuildRecord, meta: DiscordGuildMeta, sourceUserMxid = ""): tuple[ok: bool, err: string] =
  if rec.mxid.len > 0:
    return (true, "")

  discard ctx.updateInfo(rec, meta, sourceUserMxid)

  let (bridgeInfoStateKey, bridgeInfo) = ctx.getBridgeInfo(rec)

  var initialState = %*[
    {"type": "m.bridge", "content": bridgeInfo, "state_key": bridgeInfoStateKey},
    {"type": "uk.half-shot.bridge", "content": bridgeInfo, "state_key": bridgeInfoStateKey}
  ]

  if rec.avatarUrl.len > 0:
    initialState.add(%*{
      "type": "m.room.avatar",
      "content": {"url": rec.avatarUrl}
    })

  var creationContent = %*{"type": "m.space"}
  if not ctx.cfg.bridge.federateRooms:
    creationContent["m.federate"] = %false

  let roomReq = %*{
    "visibility": "private",
    "name": rec.name,
    "preset": "private_chat",
    "initial_state": initialState,
    "creation_content": creationContent,
    "room_version": "11"
  }

  let res = ctx.createRoom(roomReq)
  if not res.ok:
    return (false, res.err)

  rec.mxid = res.roomId
  rec.nameSet = true
  rec.avatarSet = rec.avatarUrl.len > 0
  ctx.runtime.guilds.upsert(rec)

  if sourceUserMxid.len > 0:
    discard ctx.ensureInvited(rec.mxid, sourceUserMxid)

  (true, "")

# ---------------------------------------------------------------------------
# cleanup — mirrors guild.cleanup
# ---------------------------------------------------------------------------

proc cleanup*(ctx: GuildContext, rec: GuildRecord) =
  if rec.mxid.len == 0:
    return
  if ctx.supportsBeeperRoomYeeting:
    discard ctx.deleteRoom(rec.mxid)
  else:
    discard ctx.cleanupRoom(rec.mxid)

# ---------------------------------------------------------------------------
# RemoveMXID — mirrors guild.RemoveMXID
# ---------------------------------------------------------------------------

proc removeMXID*(ctx: GuildContext, rec: var GuildRecord) =
  if rec.mxid.len == 0:
    return
  rec.mxid = ""
  rec.avatarSet = false
  rec.nameSet = false
  rec.bridgingMode = gbmNothing
  ctx.runtime.guilds.upsert(rec)

# ---------------------------------------------------------------------------
# Delete — mirrors guild.Delete
# ---------------------------------------------------------------------------

proc delete*(ctx: GuildContext, rec: GuildRecord) =
  ctx.runtime.guilds.delete(rec.id)
