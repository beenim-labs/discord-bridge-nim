## User session management ported from user.go — user operations, event dispatch,
## guild/channel/space handlers, login/logout/connect/disconnect, double puppeting.
##
## Uses injectable stub procs for external dependencies (Matrix API, Discord session),
## matching the pattern from portal.nim and backfill.nim.

import std/[strutils, json, options, tables, times, random]
import database/[entities, store]
import bridge/runtime
import bridge/portal

# ===========================================================================
# Error constants
# ===========================================================================

const
  ErrNotConnected* = "not connected"
  ErrNotLoggedIn*  = "not logged in"

# ===========================================================================
# Permission levels (mirrors bridgeconfig.PermissionLevel)
# ===========================================================================

type
  PermissionLevel* = enum
    plUser = 0
    plAdmin = 100

# ===========================================================================
# Bridge state events (mirrors status.BridgeStateEvent)
# ===========================================================================

type
  BridgeStateEvent* = enum
    bseConnecting         = "CONNECTING"
    bseConnected          = "CONNECTED"
    bseBackfilling        = "BACKFILLING"
    bseTransientDisconnect = "TRANSIENT_DISCONNECT"
    bseBadCredentials     = "BAD_CREDENTIALS"
    bseUnknownError       = "UNKNOWN_ERROR"
    bseUnconfigured       = "UNCONFIGURED"

  BridgeState* = object
    stateEvent*: BridgeStateEvent
    error*: string
    message*: string

# ===========================================================================
# Discord event types for dispatch
# ===========================================================================

type
  DiscordEventKind* = enum
    dekReady
    dekResumed
    dekConnect
    dekDisconnect
    dekInvalidAuth
    dekGuildCreate
    dekGuildDelete
    dekGuildUpdate
    dekGuildRoleCreate
    dekGuildRoleUpdate
    dekGuildRoleDelete
    dekChannelCreate
    dekChannelDelete
    dekChannelUpdate
    dekChannelRecipientAdd
    dekChannelRecipientRemove
    dekRelationshipAdd
    dekRelationshipRemove
    dekRelationshipUpdate
    dekMessageCreate
    dekMessageDelete
    dekMessageDeleteBulk
    dekMessageUpdate
    dekMessageReactionAdd
    dekMessageReactionRemove
    dekMessageAck
    dekTypingStart
    dekInteractionSuccess
    dekThreadListSync
    dekUnknown

  DiscordRelationship* = object
    id*: string
    nickname*: string
    relType*: int

  DiscordReadyEvent* = object
    userId*: string
    guilds*: seq[DiscordGuildMeta]
    privateChannels*: seq[DiscordChannel]
    relationships*: seq[DiscordRelationship]
    readStateVersion*: int
    readStateEntries*: seq[DiscordReadStateEntry]

  DiscordReadStateEntry* = object
    channelId*: string
    lastMessageId*: string

  DiscordGuildMeta* = object
    id*: string
    name*: string
    unavailable*: bool
    memberCount*: int
    channels*: seq[DiscordChannel]
    roles*: seq[DiscordRole]

  DiscordRole* = object
    id*: string
    name*: string
    icon*: string
    mentionable*: bool
    managed*: bool
    hoist*: bool
    color*: int
    position*: int
    permissions*: int64

  DiscordGuildDeleteEvent* = object
    id*: string
    unavailable*: bool

  DiscordThreadListSync* = object
    guildId*: string
    threads*: seq[DiscordChannel]

  DiscordMessageAck* = object
    channelId*: string
    messageId*: string
    version*: int

  DiscordTypingStartEvent* = object
    channelId*: string
    userId*: string

  DiscordInteractionSuccess* = object
    nonce*: string
    id*: string

  DiscordEvent* = object
    kind*: DiscordEventKind
    data*: JsonNode  ## raw event JSON for portal dispatch

# ===========================================================================
# Custom read markers (mirrors CustomReadReceipt / CustomReadMarkers)
# ===========================================================================

type
  CustomReadReceipt* = object
    timestamp*: int64
    doublePuppetSource*: string

  CustomReadMarkers* = object
    read*: string       ## event ID
    fullyRead*: string
    readExtra*: CustomReadReceipt
    fullyReadExtra*: CustomReadReceipt

# ===========================================================================
# Injectable stub proc types for user operations
# ===========================================================================

type
  SendBridgeStateProc*   = proc(state: BridgeState) {.closure.}
  ConnectSessionProc*    = proc(token: string): tuple[ok: bool, err: string] {.closure.}
  CloseSessionProc*      = proc(): tuple[ok: bool, err: string] {.closure.}
  SubscribeGuildProc*    = proc(guildId: string): tuple[ok: bool, err: string] {.closure.}
  MarkViewingProc*       = proc(channelId: string): tuple[ok: bool, err: string] {.closure.}
  SetReadMarkersProc*    = proc(roomId: string, markers: CustomReadMarkers): tuple[ok: bool, err: string] {.closure.}
  CreatePortalRoomProc*  = proc(portalKey: PortalKey, meta: DiscordChannel): tuple[ok: bool, err: string] {.closure.}
  UpdatePortalInfoProc*  = proc(portalKey: PortalKey, meta: DiscordChannel) {.closure.}
  ForwardBackfillProc*   = proc(portalKey: PortalKey, lastMessageId: string) {.closure.}
  HandleTypingProc*      = proc(portalKey: PortalKey, userId: string) {.closure.}
  SyncParticipantProc*   = proc(portalKey: PortalKey, userId: string, remove: bool) {.closure.}
  PushPortalMessageProc* = proc(portalKey: PortalKey, event: DiscordEvent) {.closure.}
  DeletePortalProc*      = proc(portalKey: PortalKey, cleanupOnly: bool) {.closure.}
  AddToSpaceProc*        = proc(parentRoomId, childRoomId: string): tuple[ok: bool, err: string] {.closure.}
  ReactEventProc*        = proc(roomId, eventId, emoji: string) {.closure.}
  SendWarningMsgProc*    = proc(roomId, msg: string) {.closure.}

# ===========================================================================
# UserContext — injectable context for user operations
# ===========================================================================

type
  UserContext* = ref object
    runtime*: DiscordBridgeRuntime
    bridgeName*: string

    # User record fields
    mxid*: string
    discordId*: string
    discordToken*: string
    managementRoom*: string
    spaceRoom*: string
    dmSpaceRoom*: string
    readStateVersion*: int
    permissionLevel*: PermissionLevel

    # Session state
    isConnected*: bool
    isUser*: bool  ## true for user tokens, false for bot tokens
    wasDisconnected*: bool
    wasLoggedOut*: bool

    # Tracking tables
    markedOpened*: Table[string, int64]
    relationships*: Table[string, DiscordRelationship]
    pendingInteractions*: Table[string, string]  ## nonce → event ID
    nextDiscordUploadId*: int32

    # Injectable stubs
    sendBridgeState*: SendBridgeStateProc
    connectSession*: ConnectSessionProc
    closeSession*: CloseSessionProc
    subscribeGuild*: SubscribeGuildProc
    markViewing*: MarkViewingProc
    setReadMarkers*: SetReadMarkersProc
    createPortalRoom*: CreatePortalRoomProc
    updatePortalInfo*: UpdatePortalInfoProc
    forwardBackfill*: ForwardBackfillProc
    handleTyping*: HandleTypingProc
    syncParticipant*: SyncParticipantProc
    pushPortalMsg*: PushPortalMessageProc
    deletePortal*: DeletePortalProc
    addToSpace*: AddToSpaceProc
    reactEvent*: ReactEventProc
    sendWarningMsg*: SendWarningMsgProc

# ===========================================================================
# Constructor
# ===========================================================================

proc newUserContext*(runtime: DiscordBridgeRuntime, mxid: string): UserContext =
  result = UserContext(
    runtime: runtime,
    bridgeName: "mautrix-discord",
    mxid: mxid,
    permissionLevel: plUser,
    isConnected: false,
    isUser: true,
    wasDisconnected: false,
    wasLoggedOut: false,
    markedOpened: initTable[string, int64](),
    relationships: initTable[string, DiscordRelationship](),
    pendingInteractions: initTable[string, string](),
    nextDiscordUploadId: int32(rand(99)),
  )

proc loadFromRecord*(ctx: UserContext, rec: UserRecord) =
  ctx.mxid = rec.mxid
  ctx.discordId = rec.discordId
  ctx.discordToken = rec.discordToken
  ctx.managementRoom = rec.managementRoom
  ctx.spaceRoom = rec.spaceRoom
  ctx.dmSpaceRoom = rec.dmSpaceRoom
  ctx.readStateVersion = rec.readStateVersion

proc toRecord*(ctx: UserContext): UserRecord =
  UserRecord(
    mxid: ctx.mxid,
    discordId: ctx.discordId,
    discordToken: ctx.discordToken,
    managementRoom: ctx.managementRoom,
    spaceRoom: ctx.spaceRoom,
    dmSpaceRoom: ctx.dmSpaceRoom,
    readStateVersion: ctx.readStateVersion,
    heartbeatSessionJson: "",
  )

proc updateDb*(ctx: UserContext) =
  if ctx.runtime != nil and ctx.runtime.db != nil:
    ctx.runtime.db.updateUser(ctx.toRecord())

# ===========================================================================
# Simple getters (mirrors Go trivial methods)
# ===========================================================================

proc getRemoteID*(ctx: UserContext): string = ctx.discordId

proc getRemoteName*(ctx: UserContext): string =
  if ctx.discordId.len > 0: ctx.discordId
  else: ctx.mxid

proc getPermissionLevel*(ctx: UserContext): PermissionLevel =
  ctx.permissionLevel

proc getManagementRoomID*(ctx: UserContext): string =
  ctx.managementRoom

proc getMXID*(ctx: UserContext): string =
  ctx.mxid

proc getCommandState*(ctx: UserContext): Option[JsonNode] = none(JsonNode)

proc isLoggedIn*(ctx: UserContext): bool =
  ctx.discordToken.len > 0

proc connected*(ctx: UserContext): bool =
  ctx.isConnected

# ===========================================================================
# Next Discord Upload ID
# ===========================================================================

proc nextDiscordUploadID*(ctx: UserContext): string =
  ctx.nextDiscordUploadId += 2
  $ctx.nextDiscordUploadId

# ===========================================================================
# Management room
# ===========================================================================

proc setManagementRoom*(ctx: UserContext, roomId: string) =
  ctx.managementRoom = roomId
  ctx.updateDb()

# ===========================================================================
# Space rooms
# ===========================================================================

proc getSpaceRoom*(ctx: UserContext): string = ctx.spaceRoom
proc getDMSpaceRoom*(ctx: UserContext): string = ctx.dmSpaceRoom

proc setSpaceRoom*(ctx: UserContext, roomId: string) =
  ctx.spaceRoom = roomId
  ctx.updateDb()

proc setDMSpaceRoom*(ctx: UserContext, roomId: string) =
  ctx.dmSpaceRoom = roomId
  ctx.updateDb()

# ===========================================================================
# Viewing channel (DM read-receipt suppression)
# ===========================================================================

proc viewingChannel*(ctx: UserContext, channelId: string, guildId: string): bool =
  if guildId.len > 0 or not ctx.isUser:
    return false
  if ctx.markedOpened.hasKey(channelId):
    return false
  let now = getTime().toUnix()
  ctx.markedOpened[channelId] = now
  if ctx.markViewing != nil:
    discard ctx.markViewing(channelId)
  true

# ===========================================================================
# Login / Logout / Connect / Disconnect
# ===========================================================================

proc connect*(ctx: UserContext): tuple[ok: bool, err: string] =
  if ctx.discordToken.len == 0:
    return (false, ErrNotLoggedIn)
  if ctx.connectSession != nil:
    let r = ctx.connectSession(ctx.discordToken)
    if r.ok:
      ctx.isConnected = true
    return r
  ctx.isConnected = true
  (true, "")

proc disconnect*(ctx: UserContext): tuple[ok: bool, err: string] =
  if not ctx.isConnected:
    return (false, ErrNotConnected)
  if ctx.closeSession != nil:
    let r = ctx.closeSession()
    if r.ok:
      ctx.isConnected = false
    return r
  ctx.isConnected = false
  (true, "")

proc login*(ctx: UserContext, token: string): tuple[ok: bool, err: string] =
  ctx.wasLoggedOut = false
  ctx.discordToken = token
  const maxRetries = 3
  var lastErr = ""
  for i in 0 ..< maxRetries:
    let r = ctx.connect()
    if r.ok:
      ctx.updateDb()
      return (true, "")
    lastErr = r.err
    # Fatal close codes: 4004, 4010, 4011, 4012, 4013, 4014
    if lastErr.contains("4004") or lastErr.contains("4010") or
       lastErr.contains("4011") or lastErr.contains("4012") or
       lastErr.contains("4013") or lastErr.contains("4014"):
      break
  ctx.discordToken = ""
  (false, lastErr)

proc logout*(ctx: UserContext, isOverwriting: bool) =
  if ctx.closeSession != nil:
    discard ctx.closeSession()
  ctx.isConnected = false
  ctx.discordToken = ""
  ctx.readStateVersion = 0
  ctx.discordId = ""
  ctx.updateDb()

# ===========================================================================
# Guild bridging mode
# ===========================================================================

proc getGuildBridgingMode*(ctx: UserContext, guildId: string): GuildBridgingMode =
  if guildId.len == 0:
    return gbmEverything
  if ctx.runtime == nil:
    return gbmNothing
  let guild = ctx.runtime.guilds.getByID(guildId)
  if not guild.found:
    return gbmNothing
  guild.rec.bridgingMode

# ===========================================================================
# Channel bridgeability (ported from discord.go)
# ===========================================================================

proc channelIsBridgeable*(ctx: UserContext, ch: DiscordChannel): bool =
  ## Mirrors user.channelIsBridgeable from discord.go.
  case ch.chanType
  of channelTypeDM, channelTypeGroupDM:
    return true
  of 0, 5:  # GuildText=0, GuildNews=5
    return true
  else:
    return false

# ===========================================================================
# Make read marker content
# ===========================================================================

proc makeReadMarkerContent*(ctx: UserContext, eventId: string): CustomReadMarkers =
  let extra = CustomReadReceipt(
    timestamp: 0,
    doublePuppetSource: ctx.bridgeName,
  )
  CustomReadMarkers(
    read: eventId,
    fullyRead: eventId,
    readExtra: extra,
    fullyReadExtra: extra,
  )

# ===========================================================================
# Add to space helpers
# ===========================================================================

proc addPrivateChannelToSpace*(ctx: UserContext, portalMxid: string): bool =
  if portalMxid.len == 0 or ctx.dmSpaceRoom.len == 0:
    return false
  if ctx.addToSpace != nil:
    let r = ctx.addToSpace(ctx.dmSpaceRoom, portalMxid)
    return r.ok
  false

proc addGuildToSpace*(ctx: UserContext, guildMxid: string): bool =
  if guildMxid.len == 0 or ctx.spaceRoom.len == 0:
    return false
  if ctx.addToSpace != nil:
    let r = ctx.addToSpace(ctx.spaceRoom, guildMxid)
    return r.ok
  false

# ===========================================================================
# UserPortalRecord tracking — wraps DB layer
# ===========================================================================

proc markInPortal*(ctx: UserContext, discordId: string, portalType: string,
                   inSpace: bool, timestamp: int64 = 0) =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return
  let ts = if timestamp == 0: getTime().toUnix() * 1000 else: timestamp
  let rec = UserPortalRecord(
    discordId: discordId,
    userMxid: ctx.mxid,
    portalType: portalType,
    inSpace: inSpace,
    timestampMs: ts,
  )
  ctx.runtime.db.markUserInPortal(rec)

proc markNotInPortal*(ctx: UserContext, discordId: string) =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return
  ctx.runtime.db.markUserNotInPortal(ctx.mxid, discordId)

proc isInSpace*(ctx: UserContext, discordId: string): bool =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return false
  ctx.runtime.db.isUserInSpace(ctx.mxid, discordId)

proc isInPortal*(ctx: UserContext, discordId: string): bool =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return false
  ctx.runtime.db.isUserInPortal(ctx.mxid, discordId)

proc portalHasOtherUsers*(ctx: UserContext, discordId: string): bool =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return false
  ctx.runtime.db.portalHasOtherUsers(ctx.mxid, discordId)

proc getPortals*(ctx: UserContext): seq[UserPortalRecord] =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return @[]
  ctx.runtime.db.getUserPortals(ctx.mxid)

proc prunePortalList*(ctx: UserContext, beforeTimestampMs: int64) =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return
  discard ctx.runtime.db.pruneUserPortals(ctx.mxid, beforeTimestampMs)

# ===========================================================================
# Relationship handlers
# ===========================================================================

proc isFriendRelationship(relType: int): bool =
  ## Discord relationship type 1 = friend.
  relType == 1

proc isBlockedRelationship(relType: int): bool =
  ## Discord relationship type 2 = blocked.
  relType == 2

proc handleRelationshipChange*(ctx: UserContext, userId: string, nickname: string, relType: int) =
  if ctx.runtime == nil or ctx.runtime.portals == nil:
    return
  let portals = ctx.runtime.portals.db.findPrivateChatsWith(userId, dmType = 1)
  if portals.len == 0:
    return

  for portal in portals:
    var rec = portal
    if isFriendRelationship(relType):
      rec.friendNick = true
      rec.blocked = false
      if nickname.len > 0:
        rec.name = nickname
        rec.nameSet = true
    elif isBlockedRelationship(relType):
      rec.friendNick = false
      rec.blocked = true
    else:
      rec.friendNick = false
      rec.blocked = false
    ctx.runtime.portals.upsert(rec)

proc relationshipAddHandler*(ctx: UserContext, rel: DiscordRelationship) =
  ctx.relationships[rel.id] = rel
  ctx.handleRelationshipChange(rel.id, rel.nickname, rel.relType)

proc relationshipUpdateHandler*(ctx: UserContext, rel: DiscordRelationship) =
  ctx.relationships[rel.id] = rel
  ctx.handleRelationshipChange(rel.id, rel.nickname, rel.relType)

proc relationshipRemoveHandler*(ctx: UserContext, userId: string) =
  ctx.relationships.del(userId)
  ctx.handleRelationshipChange(userId, "", 0)

# ===========================================================================
# Guild role handling
# ===========================================================================

proc discordRoleToDB*(ctx: UserContext, guildId: string, role: DiscordRole,
                       existingRole: Option[RoleRecord]): bool =
  var changed: bool
  var dbRole: RoleRecord
  if existingRole.isNone:
    dbRole = RoleRecord(id: role.id, guildId: guildId)
    changed = true
  else:
    dbRole = existingRole.get()
    changed = dbRole.name != role.name or
              dbRole.icon != role.icon or
              dbRole.mentionable != role.mentionable or
              dbRole.managed != role.managed or
              dbRole.hoist != role.hoist or
              dbRole.color != role.color or
              dbRole.position != role.position or
              dbRole.permissions != role.permissions
  dbRole.name = role.name
  dbRole.icon = role.icon
  dbRole.mentionable = role.mentionable
  dbRole.managed = role.managed
  dbRole.hoist = role.hoist
  dbRole.color = role.color
  dbRole.position = role.position
  dbRole.permissions = role.permissions
  changed

proc handleGuildRoles*(ctx: UserContext, guildId: string, newRoles: seq[DiscordRole]): int =
  var changedCount = 0
  for role in newRoles:
    if ctx.discordRoleToDB(guildId, role, none(RoleRecord)):
      inc changedCount
  changedCount

# ===========================================================================
# Private channel handler
# ===========================================================================

proc handlePrivateChannel*(ctx: UserContext, channelId: string,
                            meta: DiscordChannel, timestampMs: int64,
                            create: bool, currentlyInSpace: bool) =
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  if create:
    let existing = ctx.runtime.portals.getByID(portalKey)
    if not existing.found or existing.rec.mxid.len == 0:
      if ctx.createPortalRoom != nil:
        discard ctx.createPortalRoom(portalKey, meta)
    else:
      if ctx.updatePortalInfo != nil:
        ctx.updatePortalInfo(portalKey, meta)
      if ctx.forwardBackfill != nil:
        ctx.forwardBackfill(portalKey, "")
  else:
    if ctx.updatePortalInfo != nil:
      ctx.updatePortalInfo(portalKey, meta)
    if ctx.forwardBackfill != nil:
      ctx.forwardBackfill(portalKey, "")

  var inSpaceResult = currentlyInSpace
  if not currentlyInSpace:
    let existing = ctx.runtime.portals.getByID(portalKey)
    if existing.found and existing.rec.mxid.len > 0:
      inSpaceResult = ctx.addPrivateChannelToSpace(existing.rec.mxid)

  ctx.markInPortal(channelId, "dm", inSpaceResult, timestampMs)

# ===========================================================================
# Guild handler
# ===========================================================================

proc handleGuild*(ctx: UserContext, meta: DiscordGuildMeta,
                   timestampMs: int64, currentlyInSpace: bool) =
  if ctx.runtime == nil:
    return
  let guild = ctx.runtime.guilds.getByID(meta.id, createIfMissing = true)
  var guildRec = guild.rec
  guildRec.name = meta.name
  ctx.runtime.guilds.upsert(guildRec)

  for ch in meta.channels:
    if not ctx.channelIsBridgeable(ch):
      continue
    let portalKey = PortalKey(channelId: ch.id, receiver: "")
    let existing = ctx.runtime.portals.getByID(portalKey)
    if guildRec.bridgingMode >= gbmEverything and
       (not existing.found or existing.rec.mxid.len == 0):
      if ctx.createPortalRoom != nil:
        discard ctx.createPortalRoom(portalKey, ch)
    else:
      if ctx.updatePortalInfo != nil:
        ctx.updatePortalInfo(portalKey, ch)
      if ctx.forwardBackfill != nil:
        ctx.forwardBackfill(portalKey, "")

  if meta.roles.len > 0:
    discard ctx.handleGuildRoles(meta.id, meta.roles)

  var spaceResult = currentlyInSpace
  if guildRec.mxid.len > 0 and not currentlyInSpace:
    if ctx.addGuildToSpace(guildRec.mxid):
      spaceResult = true

  ctx.markInPortal(meta.id, "guild", spaceResult, timestampMs)

# ===========================================================================
# Connection / disconnection handlers
# ===========================================================================

proc connectedHandler*(ctx: UserContext) =
  if ctx.wasDisconnected:
    ctx.wasDisconnected = false

proc disconnectedHandler*(ctx: UserContext) =
  if ctx.wasLoggedOut:
    return
  ctx.wasDisconnected = true
  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(
      stateEvent: bseTransientDisconnect,
      error: "dc-transient-disconnect",
      message: "Temporarily disconnected from Discord, trying to reconnect",
    ))

proc invalidAuthHandler*(ctx: UserContext) =
  ctx.wasLoggedOut = true
  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(
      stateEvent: bseBadCredentials,
      error: "dc-websocket-disconnect-4004",
      message: "Discord access token is no longer valid, please log in again",
    ))
  ctx.logout(false)

proc handlePossible40002*(ctx: UserContext, errMsg: string): bool =
  if errMsg.contains("40002"):
    if ctx.sendBridgeState != nil:
      ctx.sendBridgeState(BridgeState(
        stateEvent: bseBadCredentials,
        error: "dc-http-40002",
        message: errMsg,
      ))
    return true
  false

# ===========================================================================
# Guild create/delete/update event handlers
# ===========================================================================

# Forward declaration needed because guildDeleteHandler calls unbridgeGuild
proc unbridgeGuild*(ctx: UserContext, guildId: string): tuple[ok: bool, err: string]

proc guildCreateHandler*(ctx: UserContext, meta: DiscordGuildMeta) =
  let now = getTime().toUnix() * 1000
  ctx.handleGuild(meta, now, false)

proc guildDeleteHandler*(ctx: UserContext, guildId: string, unavailable: bool) =
  if unavailable:
    return
  ctx.markNotInPortal(guildId)
  if ctx.runtime == nil:
    return
  let guild = ctx.runtime.guilds.getByID(guildId)
  if not guild.found or guild.rec.mxid.len == 0:
    return
  if not ctx.portalHasOtherUsers(guildId):
    discard ctx.unbridgeGuild(guildId)

proc guildUpdateHandler*(ctx: UserContext, meta: DiscordGuildMeta) =
  let now = getTime().toUnix() * 1000
  let inSpace = ctx.isInSpace(meta.id)
  ctx.handleGuild(meta, now, inSpace)

# ===========================================================================
# Channel event handlers
# ===========================================================================

proc channelCreateHandler*(ctx: UserContext, ch: DiscordChannel) =
  if ctx.getGuildBridgingMode(ch.guildId) < gbmEverything:
    return
  let portalKey = PortalKey(channelId: ch.id, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if existing.found and existing.rec.mxid.len > 0:
    return
  if ch.guildId.len == 0:
    let now = getTime().toUnix() * 1000
    ctx.handlePrivateChannel(ch.id, ch, now, true, ctx.isInSpace(portalKey.channelId))
  elif ctx.channelIsBridgeable(ch):
    if ctx.createPortalRoom != nil:
      discard ctx.createPortalRoom(portalKey, ch)

proc channelDeleteHandler*(ctx: UserContext, channelId: string, guildId: string) =
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if not existing.found:
    return
  if ctx.deletePortal != nil:
    ctx.deletePortal(portalKey, false)
  if guildId.len == 0:
    ctx.markNotInPortal(channelId)

proc channelUpdateHandler*(ctx: UserContext, ch: DiscordChannel) =
  let portalKey = PortalKey(channelId: ch.id, receiver: "")
  if ch.guildId.len == 0:
    let now = getTime().toUnix() * 1000
    ctx.handlePrivateChannel(ch.id, ch, now, true, ctx.isInSpace(portalKey.channelId))
  elif ctx.channelIsBridgeable(ch):
    if ctx.updatePortalInfo != nil:
      ctx.updatePortalInfo(portalKey, ch)

# ===========================================================================
# Channel recipient handlers
# ===========================================================================

proc channelRecipientAdd*(ctx: UserContext, channelId: string, userId: string) =
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if existing.found and existing.rec.mxid.len > 0:
    if ctx.syncParticipant != nil:
      ctx.syncParticipant(portalKey, userId, false)

proc channelRecipientRemove*(ctx: UserContext, channelId: string, userId: string) =
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if existing.found and existing.rec.mxid.len > 0:
    if ctx.syncParticipant != nil:
      ctx.syncParticipant(portalKey, userId, true)

# ===========================================================================
# findPortal (mirrors user.findPortal)
# ===========================================================================

proc findPortal*(ctx: UserContext, channelId: string): tuple[found: bool, portalKey: PortalKey, threadId: string] =
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if existing.found:
    return (true, portalKey, "")
  if ctx.runtime.threadRuntime != nil:
    let thread = ctx.runtime.threadRuntime.getThreadByID(channelId)
    if thread.found:
      let parentKey = PortalKey(channelId: thread.rec.parentChannelId, receiver: "")
      return (true, parentKey, thread.rec.id)
  (false, PortalKey(), "")

# ===========================================================================
# Push portal message (mirrors user.pushPortalMessage)
# ===========================================================================

proc pushPortalMessage*(ctx: UserContext, event: DiscordEvent,
                         channelId: string, guildId: string) =
  if ctx.getGuildBridgingMode(guildId) <= gbmNothing:
    return
  let found = ctx.findPortal(channelId)
  if not found.found:
    return
  let mode = ctx.getGuildBridgingMode(guildId)
  let existing = ctx.runtime.portals.getByID(found.portalKey)
  if mode <= gbmNothing or
     ((not existing.found or existing.rec.mxid.len == 0) and mode <= gbmIfPortalExists):
    return
  if ctx.pushPortalMsg != nil:
    ctx.pushPortalMsg(found.portalKey, event)

# ===========================================================================
# Message ack handler
# ===========================================================================

proc messageAckHandler*(ctx: UserContext, channelId: string,
                          messageId: string, version: int) =
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if not existing.found or existing.rec.mxid.len == 0:
    return
  if ctx.runtime.db != nil:
    let msg = ctx.runtime.db.getLastMessageByDiscordID(portalKey, messageId)
    if msg.found and msg.rec.mxid.len > 0:
      if ctx.setReadMarkers != nil:
        let markers = ctx.makeReadMarkerContent(msg.rec.mxid)
        discard ctx.setReadMarkers(existing.rec.mxid, markers)
      if ctx.readStateVersion < version:
        ctx.readStateVersion = version
        ctx.updateDb()

# ===========================================================================
# Typing handler
# ===========================================================================

proc typingStartHandler*(ctx: UserContext, channelId: string, userId: string) =
  if userId == ctx.discordId:
    return
  let portalKey = PortalKey(channelId: channelId, receiver: "")
  let existing = ctx.runtime.portals.getByID(portalKey)
  if not existing.found or existing.rec.mxid.len == 0:
    return
  if ctx.handleTyping != nil:
    ctx.handleTyping(portalKey, userId)

# ===========================================================================
# Interaction success handler
# ===========================================================================

proc interactionSuccessHandler*(ctx: UserContext, nonce: string, interactionId: string) =
  if ctx.pendingInteractions.hasKey(nonce):
    let eventId = ctx.pendingInteractions[nonce]
    if ctx.reactEvent != nil and eventId.len > 0:
      ctx.reactEvent("", eventId, "✅")
    ctx.pendingInteractions.del(nonce)

# ===========================================================================
# Thread list sync handler
# ===========================================================================

proc threadListSyncHandler*(ctx: UserContext, guildId: string,
                              threads: seq[DiscordChannel]) =
  if ctx.runtime == nil or ctx.runtime.threadRuntime == nil:
    return
  for meta in threads:
    let thread = ctx.runtime.threadRuntime.getThreadByID(meta.id)
    if not thread.found:
      if ctx.runtime.db != nil:
        let found = ctx.runtime.db.getLastMessageByDiscordID(
          PortalKey(channelId: meta.parentId, receiver: ""), meta.id)
        if found.found:
          discard  # Full implementation: threadFound
    else:
      if ctx.forwardBackfill != nil:
        let parentKey = PortalKey(channelId: thread.rec.parentChannelId, receiver: "")
        ctx.forwardBackfill(parentKey, "")

# ===========================================================================
# Subscribe guilds
# ===========================================================================

proc subscribeGuilds*(ctx: UserContext, guildIds: seq[string]) =
  if not ctx.isUser:
    return
  for guildId in guildIds:
    let guild = ctx.runtime.guilds.getByID(guildId)
    if guild.found and guild.rec.mxid.len > 0:
      if ctx.subscribeGuild != nil:
        discard ctx.subscribeGuild(guildId)

# ===========================================================================
# Ready handler
# ===========================================================================

proc readyHandler*(ctx: UserContext, evt: DiscordReadyEvent) =
  ctx.wasLoggedOut = false

  if ctx.discordId != evt.userId:
    ctx.discordId = evt.userId
    ctx.updateDb()

  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(stateEvent: bseBackfilling))

  for rel in evt.relationships:
    ctx.relationships[rel.id] = rel

  let updateTsMs = getTime().toUnix() * 1000
  var portalsInSpace = initTable[string, bool]()
  for p in ctx.getPortals():
    portalsInSpace[p.discordId] = p.inSpace

  for guild in evt.guilds:
    ctx.handleGuild(guild, updateTsMs, portalsInSpace.getOrDefault(guild.id, false))

  for ch in evt.privateChannels:
    let key = ch.id
    ctx.handlePrivateChannel(ch.id, ch, updateTsMs, true,
                              portalsInSpace.getOrDefault(key, false))

  # Apply relationship state after private channels exist so portal friend flags are correct.
  for rel in evt.relationships:
    ctx.handleRelationshipChange(rel.id, rel.nickname, rel.relType)

  ctx.prunePortalList(updateTsMs)

  if evt.readStateVersion > ctx.readStateVersion:
    for entry in evt.readStateEntries:
      ctx.messageAckHandler(entry.channelId, entry.lastMessageId, evt.readStateVersion)
    ctx.readStateVersion = evt.readStateVersion
    ctx.updateDb()

  var guildIds: seq[string] = @[]
  for guild in evt.guilds:
    guildIds.add(guild.id)
  ctx.subscribeGuilds(guildIds)

  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(stateEvent: bseConnected))

# ===========================================================================
# Resume handler
# ===========================================================================

proc resumeHandler*(ctx: UserContext) =
  if ctx.runtime == nil:
    return
  var guildIds: seq[string] = @[]
  for guild in ctx.runtime.guilds.getAll():
    if guild.mxid.len > 0:
      guildIds.add(guild.id)
  ctx.subscribeGuilds(guildIds)
  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(stateEvent: bseConnected))

# ===========================================================================
# Event dispatcher (mirrors user.eventHandler)
# ===========================================================================

proc asString(node: JsonNode, key: string): string =
  if node.kind == JObject and node.hasKey(key):
    return node[key].getStr("")
  ""

proc asInt(node: JsonNode, key: string): int =
  if node.kind == JObject and node.hasKey(key):
    return node[key].getInt(0)
  0

proc asBool(node: JsonNode, key: string): bool =
  if node.kind == JObject and node.hasKey(key):
    return node[key].getBool(false)
  false

proc parseInt64(raw: string): int64 =
  try:
    parseBiggestInt(raw).int64
  except CatchableError:
    0

proc parseDiscordRole(node: JsonNode): DiscordRole =
  DiscordRole(
    id: node.asString("id"),
    name: node.asString("name"),
    icon: node.asString("icon"),
    mentionable: node.asBool("mentionable"),
    managed: node.asBool("managed"),
    hoist: node.asBool("hoist"),
    color: node.asInt("color"),
    position: node.asInt("position"),
    permissions: parseInt64(node.asString("permissions"))
  )

proc parseDiscordChannel(node: JsonNode): DiscordChannel =
  var recipients: seq[DiscordChannelRecipient] = @[]
  if node.hasKey("recipients") and node["recipients"].kind == JArray:
    for recipient in node["recipients"]:
      if recipient.kind == JObject:
        recipients.add(DiscordChannelRecipient(id: recipient.asString("id")))
  DiscordChannel(
    id: node.asString("id"),
    name: node.asString("name"),
    topic: node.asString("topic"),
    icon: node.asString("icon"),
    parentId: node.asString("parent_id"),
    guildId: node.asString("guild_id"),
    chanType: node.asInt("type"),
    nsfw: node.asBool("nsfw"),
    unavailable: node.asBool("unavailable"),
    recipients: recipients
  )

proc parseGuildMeta(node: JsonNode): DiscordGuildMeta =
  var channels: seq[DiscordChannel] = @[]
  var roles: seq[DiscordRole] = @[]
  if node.hasKey("channels") and node["channels"].kind == JArray:
    for ch in node["channels"]:
      if ch.kind == JObject:
        channels.add(parseDiscordChannel(ch))
  if node.hasKey("roles") and node["roles"].kind == JArray:
    for role in node["roles"]:
      if role.kind == JObject:
        roles.add(parseDiscordRole(role))
  DiscordGuildMeta(
    id: node.asString("id"),
    name: node.asString("name"),
    unavailable: node.asBool("unavailable"),
    memberCount: node.asInt("member_count"),
    channels: channels,
    roles: roles
  )

proc parseReadyEvent(node: JsonNode): DiscordReadyEvent =
  var guilds: seq[DiscordGuildMeta] = @[]
  var privateChannels: seq[DiscordChannel] = @[]
  var rels: seq[DiscordRelationship] = @[]
  var readStateEntries: seq[DiscordReadStateEntry] = @[]

  if node.hasKey("guilds") and node["guilds"].kind == JArray:
    for guildNode in node["guilds"]:
      if guildNode.kind == JObject:
        guilds.add(parseGuildMeta(guildNode))
  if node.hasKey("private_channels") and node["private_channels"].kind == JArray:
    for chNode in node["private_channels"]:
      if chNode.kind == JObject:
        privateChannels.add(parseDiscordChannel(chNode))
  if node.hasKey("relationships") and node["relationships"].kind == JArray:
    for relNode in node["relationships"]:
      if relNode.kind == JObject:
        rels.add(DiscordRelationship(
          id: relNode.asString("id"),
          nickname: relNode.asString("nickname"),
          relType: relNode.asInt("type")
        ))
  if node.hasKey("read_state") and node["read_state"].kind == JObject:
    let readState = node["read_state"]
    if readState.hasKey("version"):
      discard
    if readState.hasKey("entries") and readState["entries"].kind == JArray:
      for entryNode in readState["entries"]:
        if entryNode.kind != JObject:
          continue
        readStateEntries.add(DiscordReadStateEntry(
          channelId: entryNode.asString("id"),
          lastMessageId: entryNode.asString("last_message_id")
        ))

  let userNode = if node.hasKey("user") and node["user"].kind == JObject: node["user"] else: newJObject()
  let readVersion =
    if node.hasKey("read_state") and node["read_state"].kind == JObject:
      asInt(node["read_state"], "version")
    else:
      0

  DiscordReadyEvent(
    userId: userNode.asString("id"),
    guilds: guilds,
    privateChannels: privateChannels,
    relationships: rels,
    readStateVersion: readVersion,
    readStateEntries: readStateEntries
  )

proc parseRelationship(node: JsonNode): DiscordRelationship =
  DiscordRelationship(
    id: node.asString("id"),
    nickname: node.asString("nickname"),
    relType: node.asInt("type")
  )

proc parseThreadSync(node: JsonNode): DiscordThreadListSync =
  var threads: seq[DiscordChannel] = @[]
  if node.hasKey("threads") and node["threads"].kind == JArray:
    for th in node["threads"]:
      if th.kind == JObject:
        threads.add(parseDiscordChannel(th))
  DiscordThreadListSync(
    guildId: node.asString("guild_id"),
    threads: threads
  )

proc parseMessageContext(node: JsonNode): tuple[channelId: string, guildId: string] =
  (node.asString("channel_id"), node.asString("guild_id"))

proc eventHandler*(ctx: UserContext, event: DiscordEvent) =
  case event.kind
  of dekReady:
    if event.data.kind == JObject:
      ctx.readyHandler(parseReadyEvent(event.data))
  of dekResumed:
    ctx.resumeHandler()
  of dekConnect:
    ctx.connectedHandler()
  of dekDisconnect:
    ctx.disconnectedHandler()
  of dekInvalidAuth:
    ctx.invalidAuthHandler()
  of dekGuildCreate:
    if event.data.kind == JObject:
      ctx.guildCreateHandler(parseGuildMeta(event.data))
  of dekGuildUpdate:
    if event.data.kind == JObject:
      ctx.guildUpdateHandler(parseGuildMeta(event.data))
  of dekGuildDelete:
    if event.data.kind == JObject:
      ctx.guildDeleteHandler(event.data.asString("id"), event.data.asBool("unavailable"))
  of dekGuildRoleCreate, dekGuildRoleUpdate, dekGuildRoleDelete:
    discard
  of dekChannelCreate:
    if event.data.kind == JObject:
      ctx.channelCreateHandler(parseDiscordChannel(event.data))
  of dekChannelDelete:
    if event.data.kind == JObject:
      ctx.channelDeleteHandler(event.data.asString("id"), event.data.asString("guild_id"))
  of dekChannelUpdate:
    if event.data.kind == JObject:
      ctx.channelUpdateHandler(parseDiscordChannel(event.data))
  of dekChannelRecipientAdd:
    if event.data.kind == JObject:
      let userNode =
        if event.data.hasKey("user") and event.data["user"].kind == JObject:
          event.data["user"]
        else:
          newJObject()
      ctx.channelRecipientAdd(event.data.asString("channel_id"), userNode.asString("id"))
  of dekChannelRecipientRemove:
    if event.data.kind == JObject:
      let userNode =
        if event.data.hasKey("user") and event.data["user"].kind == JObject:
          event.data["user"]
        else:
          newJObject()
      ctx.channelRecipientRemove(event.data.asString("channel_id"), userNode.asString("id"))
  of dekRelationshipAdd:
    if event.data.kind == JObject:
      ctx.relationshipAddHandler(parseRelationship(event.data))
  of dekRelationshipUpdate:
    if event.data.kind == JObject:
      ctx.relationshipUpdateHandler(parseRelationship(event.data))
  of dekRelationshipRemove:
    if event.data.kind == JObject:
      ctx.relationshipRemoveHandler(event.data.asString("id"))
  of dekMessageCreate, dekMessageUpdate, dekMessageReactionAdd, dekMessageReactionRemove:
    if event.data.kind == JObject:
      let (channelId, guildId) = parseMessageContext(event.data)
      ctx.pushPortalMessage(event, channelId, guildId)
  of dekMessageDelete:
    if event.data.kind == JObject:
      let (channelId, guildId) = parseMessageContext(event.data)
      ctx.pushPortalMessage(event, channelId, guildId)
  of dekMessageDeleteBulk:
    if event.data.kind == JObject:
      let (channelId, guildId) = parseMessageContext(event.data)
      ctx.pushPortalMessage(event, channelId, guildId)
  of dekMessageAck:
    if event.data.kind == JObject:
      ctx.messageAckHandler(
        event.data.asString("channel_id"),
        event.data.asString("message_id"),
        event.data.asInt("version")
      )
  of dekTypingStart:
    if event.data.kind == JObject:
      let userNode =
        if event.data.hasKey("user") and event.data["user"].kind == JObject:
          event.data["user"]
        else:
          newJObject()
      ctx.typingStartHandler(event.data.asString("channel_id"), userNode.asString("id"))
  of dekInteractionSuccess:
    if event.data.kind == JObject:
      ctx.interactionSuccessHandler(event.data.asString("nonce"), event.data.asString("id"))
  of dekThreadListSync:
    if event.data.kind == JObject:
      let parsed = parseThreadSync(event.data)
      ctx.threadListSyncHandler(parsed.guildId, parsed.threads)
  of dekUnknown:
    discard

# ===========================================================================
# Direct chats (mirrors user.getDirectChats / user.updateDirectChats)
# ===========================================================================

proc getDirectChats*(ctx: UserContext): seq[tuple[puppetMxid: string, roomId: string]] =
  if ctx.runtime == nil or ctx.runtime.db == nil:
    return @[]
  let privates = ctx.runtime.db.findPrivateChatsOf(ctx.discordId)
  result = @[]
  for p in privates:
    if p.mxid.len > 0:
      result.add((puppetMxid: p.otherUserId, roomId: p.mxid))

# ===========================================================================
# Startup try connect (mirrors user.startupTryConnect)
# ===========================================================================

proc startupTryConnect*(ctx: UserContext, retryCount: int, maxRetries: int = 6): tuple[ok: bool, err: string] =
  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(stateEvent: bseConnecting))
  let r = ctx.connect()
  if r.ok:
    return (true, "")
  if r.err.contains("4004"):
    ctx.invalidAuthHandler()
    return (false, r.err)
  if retryCount < maxRetries:
    if ctx.sendBridgeState != nil:
      ctx.sendBridgeState(BridgeState(
        stateEvent: bseTransientDisconnect,
        error: "dc-unknown-websocket-error",
        message: r.err,
      ))
    return (false, r.err)
  if ctx.sendBridgeState != nil:
    ctx.sendBridgeState(BridgeState(
      stateEvent: bseUnknownError,
      error: "dc-unknown-websocket-error",
      message: r.err,
    ))
  (false, r.err)

# ===========================================================================
# Bridge / unbridge guild (mirrors user.bridgeGuild / user.unbridgeGuild)
# ===========================================================================

proc bridgeGuild*(ctx: UserContext, guildId: string, everything: bool): tuple[ok: bool, err: string] =
  if ctx.runtime == nil:
    return (false, "runtime not initialized")
  let guild = ctx.runtime.guilds.getByID(guildId)
  if not guild.found:
    return (false, "guild not found")
  var rec = guild.rec
  if everything:
    rec.bridgingMode = gbmEverything
  else:
    rec.bridgingMode = gbmCreateOnMessage
  ctx.runtime.guilds.upsert(rec)
  discard ctx.addGuildToSpace(rec.mxid)
  if ctx.subscribeGuild != nil and ctx.isUser:
    discard ctx.subscribeGuild(guildId)
  (true, "")

proc unbridgeGuild*(ctx: UserContext, guildId: string): tuple[ok: bool, err: string] =
  if ctx.runtime == nil:
    return (false, "runtime not initialized")
  if ctx.permissionLevel < plAdmin and ctx.portalHasOtherUsers(guildId):
    return (false, "only bridge admins can unbridge guilds with other users")
  let guild = ctx.runtime.guilds.getByID(guildId)
  if not guild.found:
    return (false, "guild not found")
  var rec = guild.rec
  if rec.bridgingMode == gbmNothing and rec.mxid.len == 0:
    return (false, "that guild is not bridged")
  rec.bridgingMode = gbmNothing
  ctx.runtime.guilds.upsert(rec)
  (true, "")

# ===========================================================================
# Ensure invited (mirrors user.ensureInvited)
# ===========================================================================

proc ensureInvited*(ctx: UserContext, roomId: string, isDirect: bool): bool =
  if roomId.len == 0:
    return false
  true
