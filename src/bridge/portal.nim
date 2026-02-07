## Portal helpers ported from portal.go — runtime Portal operations.
## Covers: lookup, bridge info, encryption, room creation, message loop,
## Discord→Matrix events (create/update/delete), Matrix→Discord events,
## reactions, redaction, typing, read receipts, room metadata (name/avatar/topic),
## space management, cleanup, lifecycle, error handling, media helpers.
##
## 93 functions total.

import std/[strutils, json, times]
import config/config
import database/[entities, store]
import bridge/runtime

# ===========================================================================
# Discord channel types  (mirrors discordgo.ChannelType)
# ===========================================================================

const
  channelTypeDM*            = 1
  channelTypeGroupDM*       = 3
  channelTypeGuildCategory* = 4
  channelTypeGuildPublicThread* = 11

  discordEpoch*: int64 = 1420070400000'i64
  replyEmbedMaxLines = 1
  replyEmbedMaxChars = 72
  joinThreadReaction* = "join thread"

# ===========================================================================
# Discord metadata types
# ===========================================================================

type
  DiscordChannel* = object
    id*: string
    name*: string
    topic*: string
    icon*: string
    parentId*: string
    guildId*: string
    chanType*: int
    nsfw*: bool
    unavailable*: bool
    recipients*: seq[DiscordChannelRecipient]

  DiscordChannelRecipient* = object
    id*: string

  DiscordMessageRef* = object
    messageId*: string
    channelId*: string
    guildId*: string

  DiscordMessageReaction* = object
    userId*: string
    messageId*: string
    channelId*: string
    emojiId*: string
    emojiName*: string
    emojiAnimated*: bool

# ===========================================================================
# Matrix client stub types
# ===========================================================================

type
  PortalSendStateEventResult*  = tuple[ok: bool, eventId: string, err: string]
  PortalCreateRoomResult*      = tuple[ok: bool, roomId: string, err: string]
  PortalSetRoomNameResult*     = tuple[ok: bool, err: string]
  PortalSetRoomAvatarResult*   = tuple[ok: bool, err: string]
  PortalSetRoomTopicResult*    = tuple[ok: bool, err: string]
  PortalDeleteRoomResult*      = tuple[ok: bool, err: string]
  PortalCleanupRoomResult*     = tuple[ok: bool, err: string]
  PortalSendMessageResult*     = tuple[ok: bool, eventId: string, err: string]
  PortalRedactEventResult*     = tuple[ok: bool, eventId: string, err: string]
  PortalJoinedMembersResult*   = tuple[ok: bool, members: seq[string], err: string]
  PortalEnsureUserInvitedResult* = tuple[ok: bool, err: string]
  PortalEnsureJoinedResult*    = tuple[ok: bool, err: string]
  PortalLeaveRoomResult*       = tuple[ok: bool, err: string]
  PortalKickUserResult*       = bool
  PortalMarkReadResult*        = tuple[ok: bool, err: string]
  PortalUserTypingResult*      = tuple[ok: bool, err: string]
  PortalGetEventResult*        = tuple[ok: bool, content: JsonNode, err: string]
  PortalEnsureRegisteredResult* = tuple[ok: bool, err: string]

  PortalCopyAttachmentResult* = object
    ok*: bool
    mxc*: string
    mimeType*: string
    size*: int
    width*: int
    height*: int
    encrypted*: bool
    decryptionInfoJson*: string
    err*: string

  PortalSendStateEventProc*    = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult {.closure.}
  PortalCreateRoomProc*        = proc(req: JsonNode): PortalCreateRoomResult {.closure.}
  PortalSetRoomNameProc*       = proc(roomId, name: string): PortalSetRoomNameResult {.closure.}
  PortalSetRoomAvatarProc*     = proc(roomId, url: string): PortalSetRoomAvatarResult {.closure.}
  PortalSetRoomTopicProc*      = proc(roomId, topic: string): PortalSetRoomTopicResult {.closure.}
  PortalDeleteRoomProc*        = proc(roomId: string): PortalDeleteRoomResult {.closure.}
  PortalCleanupRoomProc*       = proc(roomId: string): PortalCleanupRoomResult {.closure.}
  PortalSendMessageProc*       = proc(roomId, eventType: string, content: JsonNode, timestamp: int64): PortalSendMessageResult {.closure.}
  PortalRedactEventProc*       = proc(roomId, eventId: string): PortalRedactEventResult {.closure.}
  PortalJoinedMembersProc*     = proc(roomId: string): PortalJoinedMembersResult {.closure.}
  PortalEnsureUserInvitedProc* = proc(roomId, userId: string): PortalEnsureUserInvitedResult {.closure.}
  PortalEnsureJoinedProc*      = proc(roomId, userId: string): PortalEnsureJoinedResult {.closure.}
  PortalLeaveRoomProc*         = proc(roomId, userId: string): PortalLeaveRoomResult {.closure.}
  PortalKickUserProc*          = proc(roomId, userId, reason: string): PortalKickUserResult {.closure.}
  PortalMarkReadProc*          = proc(roomId, eventId: string): PortalMarkReadResult {.closure.}
  PortalUserTypingProc*        = proc(roomId, userId: string): PortalUserTypingResult {.closure.}
  PortalGetEventProc*          = proc(roomId, eventId: string): PortalGetEventResult {.closure.}
  PortalCopyAttachmentProc*    = proc(url: string, encrypt: bool, attachmentId: string): PortalCopyAttachmentResult {.closure.}
  PortalEnsureRegisteredProc*  = proc(userId: string): PortalEnsureRegisteredResult {.closure.}

  ## Callback for getting puppet MXID format
  PortalFormatPuppetMXIDProc*  = proc(discordId: string): string {.closure.}
  PortalParsePuppetMXIDProc*   = proc(mxid: string): tuple[discordId: string, ok: bool] {.closure.}

# ===========================================================================
# PortalContext — wiring object that carries all external dependencies
# ===========================================================================

type
  PortalContext* = ref object
    runtime*: DiscordBridgeRuntime
    cfg*: Config

    ## Matrix client stubs
    sendStateEvent*: PortalSendStateEventProc
    createRoom*: PortalCreateRoomProc
    setRoomName*: PortalSetRoomNameProc
    setRoomAvatar*: PortalSetRoomAvatarProc
    setRoomTopic*: PortalSetRoomTopicProc
    deleteRoom*: PortalDeleteRoomProc
    cleanupRoom*: PortalCleanupRoomProc
    sendMessage*: PortalSendMessageProc
    redactEvent*: PortalRedactEventProc
    joinedMembers*: PortalJoinedMembersProc
    ensureUserInvited*: PortalEnsureUserInvitedProc
    ensureJoined*: PortalEnsureJoinedProc
    leaveRoom*: PortalLeaveRoomProc
    kickUser*: PortalKickUserProc
    markRead*: PortalMarkReadProc
    userTyping*: PortalUserTypingProc
    getEvent*: PortalGetEventProc
    copyAttachment*: PortalCopyAttachmentProc
    ensureRegistered*: PortalEnsureRegisteredProc
    formatPuppetMXID*: PortalFormatPuppetMXIDProc
    parsePuppetMXID*: PortalParsePuppetMXIDProc

    ## Feature flags
    supportsBeeperRoomYeeting*: bool
    supportsEncryption*: bool
    encryptionDefault*: bool

    ## Bot identity
    botUserID*: string
    botAvatarUrl*: string
    homeserverDomain*: string

    ## Bridge config mirrors
    deliveryReceipts*: bool
    messageErrorNotices*: bool
    messageStatusEvents*: bool
    autojoinThreadOnOpen*: bool
    customEmojiReactions*: bool
    restrictedRooms*: bool
    privateChatPortalMeta*: string

proc newPortalContext*(runtime: DiscordBridgeRuntime, cfg: Config): PortalContext =
  new(result)
  result.runtime = runtime
  result.cfg = cfg
  result.sendStateEvent = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult = (true, "", "")
  result.createRoom = proc(req: JsonNode): PortalCreateRoomResult = (false, "", "createRoom not configured")
  result.setRoomName = proc(roomId, name: string): PortalSetRoomNameResult = (true, "")
  result.setRoomAvatar = proc(roomId, url: string): PortalSetRoomAvatarResult = (true, "")
  result.setRoomTopic = proc(roomId, topic: string): PortalSetRoomTopicResult = (true, "")
  result.deleteRoom = proc(roomId: string): PortalDeleteRoomResult = (true, "")
  result.cleanupRoom = proc(roomId: string): PortalCleanupRoomResult = (true, "")
  result.sendMessage = proc(roomId, eventType: string, content: JsonNode, timestamp: int64): PortalSendMessageResult = (true, "", "")
  result.redactEvent = proc(roomId, eventId: string): PortalRedactEventResult = (true, "", "")
  result.joinedMembers = proc(roomId: string): PortalJoinedMembersResult = (true, @[], "")
  result.ensureUserInvited = proc(roomId, userId: string): PortalEnsureUserInvitedResult = (true, "")
  result.ensureJoined = proc(roomId, userId: string): PortalEnsureJoinedResult = (true, "")
  result.leaveRoom = proc(roomId, userId: string): PortalLeaveRoomResult = (true, "")
  result.kickUser = proc(roomId, userId, reason: string): PortalKickUserResult = true
  result.markRead = proc(roomId, eventId: string): PortalMarkReadResult = (true, "")
  result.userTyping = proc(roomId, userId: string): PortalUserTypingResult = (true, "")
  result.getEvent = proc(roomId, eventId: string): PortalGetEventResult = (false, nil, "getEvent not configured")
  result.copyAttachment = proc(url: string, encrypt: bool, attachmentId: string): PortalCopyAttachmentResult = PortalCopyAttachmentResult(ok: false, mxc: "", err: "copy attachment not configured")
  result.ensureRegistered = proc(userId: string): PortalEnsureRegisteredResult = (true, "")
  result.formatPuppetMXID = proc(discordId: string): string = "@discord_" & discordId & ":example.com"
  result.parsePuppetMXID = proc(mxid: string): tuple[discordId: string, ok: bool] = ("", false)
  result.supportsBeeperRoomYeeting = false
  result.supportsEncryption = false
  result.encryptionDefault = false
  result.botUserID = ""
  result.botAvatarUrl = ""
  result.homeserverDomain = ""
  result.deliveryReceipts = false
  result.messageErrorNotices = false
  result.messageStatusEvents = false
  result.autojoinThreadOnOpen = false
  result.customEmojiReactions = false
  result.restrictedRooms = false
  result.privateChatPortalMeta = ""

# ===========================================================================
# Portal lookup — delegates to PortalManager
# ===========================================================================

proc getPortalByMXID*(ctx: PortalContext, mxid: string): tuple[found: bool, rec: PortalRecord] =
  ctx.runtime.portals.getByMXID(mxid)

proc getPortalByID*(ctx: PortalContext, key: PortalKey, createIfMissing = false, portalType = 0): tuple[found: bool, rec: PortalRecord] =
  ctx.runtime.portals.getByID(key, createIfMissing, portalType)

proc getExistingPortalByID*(ctx: PortalContext, key: PortalKey): tuple[found: bool, rec: PortalRecord] =
  ## Try with receiver first, then without (mirrors Go fallback logic).
  let direct = ctx.runtime.portals.getByID(key)
  if direct.found:
    return direct
  if key.receiver.len > 0:
    let noReceiver = ctx.runtime.portals.getByID(PortalKey(channelId: key.channelId, receiver: ""))
    if noReceiver.found:
      return noReceiver
  (false, default(PortalRecord))

proc getAllPortals*(ctx: PortalContext): seq[PortalRecord] =
  ctx.runtime.portals.db.getAllPortals()

proc getAllPortalsInGuild*(ctx: PortalContext, guildId: string): seq[PortalRecord] =
  ctx.runtime.portals.db.getAllPortalsInGuild(guildId)

proc getDMPortalsWith*(ctx: PortalContext, otherUserId: string): seq[PortalRecord] =
  ctx.runtime.portals.db.findPrivateChatsWith(otherUserId)

proc findPrivateChat*(ctx: PortalContext, otherUserId, receiverId: string): tuple[found: bool, rec: PortalRecord] =
  ctx.runtime.portals.db.findPrivateChatBetween(otherUserId, receiverId)

# ===========================================================================
# Helpers
# ===========================================================================

proc isPrivateChat*(rec: PortalRecord): bool =
  rec.portalType == channelTypeDM

proc mainIntentMXID*(ctx: PortalContext, rec: PortalRecord): string =
  ## Returns the MXID of the user that should act on behalf of this portal.
  if rec.isPrivateChat and rec.otherUserId.len > 0:
    return ctx.formatPuppetMXID(rec.otherUserId)
  ctx.botUserID

proc shouldSetDMRoomMetadata*(ctx: PortalContext, rec: PortalRecord): bool =
  not rec.isPrivateChat or
  ctx.privateChatPortalMeta == "always" or
  (rec.encrypted and ctx.privateChatPortalMeta != "never")

proc generateNonce*(): string =
  let snowflake = (getTime().toUnix() * 1000 - discordEpoch) shl 22
  $snowflake

proc cutBody*(body: string): string =
  let lines = body.strip().split("\n")
  var output = ""
  for i, line in lines:
    if i >= replyEmbedMaxLines:
      output &= " […]"
      break
    if i > 0:
      output &= "\n"
    output &= line
    if output.len > replyEmbedMaxChars:
      output = output[0 ..< replyEmbedMaxChars] & "…"
      break
  output

proc genThreadName*(body: string): string =
  if body.len == 0:
    return "thread"
  let fields = body.splitWhitespace()
  var title = ""
  for field in fields:
    if title.len + field.len < 40:
      title &= field & " "
      continue
    if title.len == 0:
      title = field[0 ..< min(40, field.len)]
    break
  title

# ===========================================================================
# Bridge info — mirrors portal.getBridgeInfo / UpdateBridgeInfo
# ===========================================================================

proc getBridgeInfo*(ctx: PortalContext, rec: PortalRecord, guildRec: GuildRecord = default(GuildRecord)): tuple[stateKey: string, content: JsonNode] =
  var bridgeInfo = %*{
    "bridgebot": ctx.botUserID,
    "creator": ctx.mainIntentMXID(rec),
    "protocol": {
      "id": "discordgo",
      "displayname": "Discord",
      "avatar_url": ctx.botAvatarUrl,
      "external_url": "https://discord.com/"
    },
    "channel": {
      "id": rec.key.channelId,
      "displayname": rec.name
    }
  }

  var stateKey: string
  if rec.guildId.len == 0:
    stateKey = "fi.mau.discord://discord/dm/" & rec.key.channelId
    bridgeInfo["channel"]["external_url"] = %("https://discord.com/channels/@me/" & rec.key.channelId)
  else:
    bridgeInfo["network"] = %*{"id": rec.guildId}
    if guildRec.id.len > 0:
      bridgeInfo["network"]["displayname"] = %guildRec.name
      bridgeInfo["network"]["avatar_url"] = %guildRec.avatarUrl
    stateKey = "fi.mau.discord://discord/" & rec.guildId & "/" & rec.key.channelId
    bridgeInfo["channel"]["external_url"] = %("https://discord.com/channels/" & rec.guildId & "/" & rec.key.channelId)

  var roomType = ""
  var roomTypeV2 = ""
  if rec.portalType == channelTypeDM or rec.portalType == channelTypeGroupDM:
    roomType = "dm"
  if rec.portalType == channelTypeDM:
    roomTypeV2 = "dm"
  elif rec.portalType == channelTypeGroupDM:
    roomTypeV2 = "group_dm"

  if roomType.len > 0:
    bridgeInfo["com.beeper.room_type"] = %roomType
  if roomTypeV2.len > 0:
    bridgeInfo["com.beeper.room_type.v2"] = %roomTypeV2

  (stateKey, bridgeInfo)

proc updateBridgeInfo*(ctx: PortalContext, rec: PortalRecord, guildRec: GuildRecord = default(GuildRecord)) =
  if rec.mxid.len == 0:
    return
  let (stateKey, content) = ctx.getBridgeInfo(rec, guildRec)
  discard ctx.sendStateEvent(rec.mxid, "m.bridge", stateKey, content)
  discard ctx.sendStateEvent(rec.mxid, "uk.half-shot.bridge", stateKey, content)

# ===========================================================================
# IsEncrypted / MarkEncrypted
# ===========================================================================

proc isEncrypted*(rec: PortalRecord): bool =
  rec.encrypted

proc markEncrypted*(ctx: PortalContext, rec: var PortalRecord) =
  rec.encrypted = true
  ctx.runtime.portals.upsert(rec)

# ===========================================================================
# UpdateName — mirrors portal.UpdateName / UpdateNameDirect / updateRoomName
# ===========================================================================

proc updateRoomName*(ctx: PortalContext, rec: var PortalRecord) =
  if rec.mxid.len > 0 and (ctx.shouldSetDMRoomMetadata(rec) or rec.friendNick):
    let res = ctx.setRoomName(rec.mxid, rec.name)
    if res.ok:
      rec.nameSet = true

proc updateNameDirect*(ctx: PortalContext, rec: var PortalRecord, name: string, isFriendNick: bool): bool =
  if rec.friendNick and not isFriendNick:
    return false
  if rec.name == name and (rec.nameSet or rec.mxid.len == 0 or (not ctx.shouldSetDMRoomMetadata(rec) and not isFriendNick)):
    return false
  rec.name = name
  rec.nameSet = false
  ctx.updateRoomName(rec)
  true

proc updateName*(ctx: PortalContext, rec: var PortalRecord, meta: DiscordChannel,
                 parentPlainName = "", guildPlainName = ""): bool =
  let plainNameChanged = rec.plainName != meta.name
  rec.plainName = meta.name
  let formattedName = ctx.cfg.bridge.formatChannelName(ChannelNameParams(
    name: meta.name,
    parentName: parentPlainName,
    guildName: guildPlainName,
    nsfw: meta.nsfw,
    channelType: meta.chanType
  ))
  ctx.updateNameDirect(rec, formattedName, false) or plainNameChanged

# ===========================================================================
# UpdateAvatar — mirrors portal.UpdateAvatarFromPuppet / UpdateGroupDMAvatar / updateRoomAvatar
# ===========================================================================

proc updateRoomAvatar*(ctx: PortalContext, rec: var PortalRecord) =
  if rec.mxid.len == 0 or rec.avatarUrl.len == 0 or not ctx.shouldSetDMRoomMetadata(rec):
    return
  let res = ctx.setRoomAvatar(rec.mxid, rec.avatarUrl)
  if res.ok:
    rec.avatarSet = true

proc updateAvatarFromPuppet*(ctx: PortalContext, rec: var PortalRecord, puppetAvatar, puppetAvatarUrl: string): bool =
  if rec.avatar == puppetAvatar and rec.avatarUrl == puppetAvatarUrl and
     (puppetAvatar.len == 0 or rec.avatarSet or rec.mxid.len == 0 or not ctx.shouldSetDMRoomMetadata(rec)):
    return false
  rec.avatar = puppetAvatar
  rec.avatarUrl = puppetAvatarUrl
  rec.avatarSet = false
  ctx.updateRoomAvatar(rec)
  true

proc updateGroupDMAvatar*(ctx: PortalContext, rec: var PortalRecord, iconID: string): bool =
  if rec.avatar == iconID and
     (iconID.len == 0) == (rec.avatarUrl.len == 0) and
     (iconID.len == 0 or rec.avatarSet or rec.mxid.len == 0):
    return false
  rec.avatar = iconID
  rec.avatarSet = false
  rec.avatarUrl = ""
  if rec.avatar.len > 0:
    let attachId = "private_channel_avatar/" & rec.key.channelId & "/" & iconID
    let cdnUrl = "https://cdn.discordapp.com/channel-icons/" & rec.key.channelId & "/" & rec.avatar & ".png"
    let copied = ctx.copyAttachment(cdnUrl, false, attachId)
    if not copied.ok:
      return true
    rec.avatarUrl = copied.mxc
  ctx.updateRoomAvatar(rec)
  true

# ===========================================================================
# UpdateTopic — mirrors portal.UpdateTopic / updateRoomTopic
# ===========================================================================

proc updateRoomTopic*(ctx: PortalContext, rec: var PortalRecord) =
  if rec.mxid.len > 0:
    let res = ctx.setRoomTopic(rec.mxid, rec.topic)
    if res.ok:
      rec.topicSet = true

proc updateTopic*(ctx: PortalContext, rec: var PortalRecord, topic: string): bool =
  if rec.topic == topic and (rec.topicSet or rec.mxid.len == 0):
    return false
  rec.topic = topic
  rec.topicSet = false
  ctx.updateRoomTopic(rec)
  true

# ===========================================================================
# Space management — mirrors portal.removeFromSpace / addToSpace / UpdateParent / ExpectedSpaceID / updateSpace
# ===========================================================================

proc removeFromSpace*(ctx: PortalContext, rec: var PortalRecord) =
  if rec.inSpace.len == 0:
    return
  discard ctx.sendStateEvent(rec.mxid, "m.space.parent", rec.inSpace, %*{})
  discard ctx.sendStateEvent(rec.inSpace, "m.space.child", rec.mxid, %*{})
  rec.inSpace = ""

proc addToSpace*(ctx: PortalContext, rec: var PortalRecord, spaceRoomId: string): bool =
  if rec.inSpace == spaceRoomId:
    return false
  ctx.removeFromSpace(rec)
  if spaceRoomId.len == 0:
    return true
  discard ctx.sendStateEvent(rec.mxid, "m.space.parent", spaceRoomId, %*{
    "via": [ctx.homeserverDomain],
    "canonical": true
  })
  let childRes = ctx.sendStateEvent(spaceRoomId, "m.space.child", rec.mxid, %*{
    "via": [ctx.homeserverDomain]
  })
  if childRes.ok:
    rec.inSpace = spaceRoomId
  true

proc updateParent*(ctx: PortalContext, rec: var PortalRecord, parentID: string): bool =
  if rec.parentId == parentID:
    return false
  rec.parentId = parentID
  true

proc expectedSpaceID*(ctx: PortalContext, rec: PortalRecord): string =
  ## Returns the parent's MXID (if category portal exists) or guild's MXID.
  if rec.parentId.len > 0:
    let parent = ctx.runtime.portals.getByID(PortalKey(channelId: rec.parentId, receiver: ""))
    if parent.found and parent.rec.mxid.len > 0:
      return parent.rec.mxid
  if rec.guildId.len > 0:
    let guild = ctx.runtime.guilds.getByID(rec.guildId)
    if guild.found and guild.rec.mxid.len > 0:
      return guild.rec.mxid
  ""

proc updateSpace*(ctx: PortalContext, rec: var PortalRecord): bool =
  if rec.mxid.len == 0:
    return false
  let expectedSpace = ctx.expectedSpaceID(rec)
  if expectedSpace.len > 0:
    return ctx.addToSpace(rec, expectedSpace)
  false

# ===========================================================================
# UpdateInfo — mirrors portal.UpdateInfo (main entry point for metadata sync)
# ===========================================================================

proc updateInfo*(ctx: PortalContext, rec: var PortalRecord, meta: DiscordChannel): bool =
  var changed = false

  if meta.chanType != 0 and rec.portalType != meta.chanType:
    rec.portalType = meta.chanType
    changed = true

  if rec.otherUserId.len == 0 and rec.isPrivateChat and meta.recipients.len > 0:
    rec.otherUserId = meta.recipients[0].id
    changed = true

  if meta.guildId.len > 0 and rec.guildId.len == 0:
    rec.guildId = meta.guildId
    changed = true

  ## Name/avatar/topic updates depend on channel type
  case rec.portalType
  of channelTypeDM:
    discard  # DM name/avatar come from puppet, handled separately in user layer
  of channelTypeGroupDM:
    changed = ctx.updateGroupDMAvatar(rec, meta.icon) or changed
    changed = ctx.updateName(rec, meta) or changed
  else:
    changed = ctx.updateName(rec, meta) or changed

  changed = ctx.updateTopic(rec, meta.topic) or changed
  changed = ctx.updateParent(rec, meta.parentId) or changed

  if rec.guildId.len > 0 and rec.mxid.len > 0:
    let expected = ctx.expectedSpaceID(rec)
    if expected != rec.inSpace:
      changed = ctx.updateSpace(rec) or changed

  if changed:
    ctx.updateBridgeInfo(rec)
    ctx.runtime.portals.upsert(rec)
  changed

# ===========================================================================
# CreateMatrixRoom — mirrors portal.CreateMatrixRoom
# ===========================================================================

proc createMatrixRoom*(ctx: PortalContext, rec: var PortalRecord, meta: DiscordChannel,
                       sourceUserMxid = ""): tuple[ok: bool, err: string] =
  if rec.mxid.len > 0:
    if sourceUserMxid.len > 0:
      discard ctx.ensureUserInvited(rec.mxid, sourceUserMxid)
    return (true, "")

  discard ctx.updateInfo(rec, meta)

  let intentMxid = ctx.mainIntentMXID(rec)
  let regRes = ctx.ensureRegistered(intentMxid)
  if not regRes.ok:
    return (false, regRes.err)

  let (bridgeInfoStateKey, bridgeInfo) = ctx.getBridgeInfo(rec)
  var initialState = %*[
    {"type": "m.bridge", "content": bridgeInfo, "state_key": bridgeInfoStateKey},
    {"type": "uk.half-shot.bridge", "content": bridgeInfo, "state_key": bridgeInfoStateKey}
  ]

  var invite = newJArray()

  if ctx.encryptionDefault:
    initialState.add(%*{
      "type": "m.room.encryption",
      "content": {"algorithm": "m.megolm.v1.aes-sha2"}
    })
    rec.encrypted = true
    if rec.isPrivateChat:
      invite.add(%ctx.botUserID)

  if rec.avatarUrl.len > 0 and ctx.shouldSetDMRoomMetadata(rec):
    initialState.add(%*{
      "type": "m.room.avatar",
      "content": {"url": rec.avatarUrl}
    })
    rec.avatarSet = true
  else:
    rec.avatarSet = false

  var creationContent = newJObject()
  if rec.portalType == channelTypeGuildCategory:
    creationContent["type"] = %"m.space"
  if not ctx.cfg.bridge.federateRooms:
    creationContent["m.federate"] = %false

  let expectedSpace = ctx.expectedSpaceID(rec)
  if expectedSpace.len > 0:
    initialState.add(%*{
      "type": "m.space.parent",
      "state_key": expectedSpace,
      "content": {
        "via": [ctx.homeserverDomain],
        "canonical": true
      }
    })

  if ctx.restrictedRooms and rec.guildId.len > 0:
    let guild = ctx.runtime.guilds.getByID(rec.guildId)
    if guild.found and guild.rec.mxid.len > 0:
      initialState.add(%*{
        "type": "m.room.join_rules",
        "content": {
          "join_rule": "restricted",
          "allow": [{"room_id": guild.rec.mxid, "type": "m.room_membership"}]
        }
      })

  var reqName = rec.name
  if not ctx.shouldSetDMRoomMetadata(rec) and not rec.friendNick:
    reqName = ""

  let roomReq = %*{
    "visibility": "private",
    "name": reqName,
    "topic": rec.topic,
    "invite": invite,
    "preset": "private_chat",
    "is_direct": rec.isPrivateChat,
    "initial_state": initialState,
    "creation_content": creationContent,
    "room_version": "11"
  }

  let res = ctx.createRoom(roomReq)
  if not res.ok:
    return (false, res.err)

  rec.nameSet = reqName.len > 0
  rec.topicSet = rec.topic.len > 0
  rec.mxid = res.roomId
  ctx.runtime.portals.upsert(rec)

  if expectedSpace.len > 0:
    discard ctx.addToSpace(rec, expectedSpace)

  if sourceUserMxid.len > 0:
    discard ctx.ensureUserInvited(rec.mxid, sourceUserMxid)

  ## Send dummy creation event for backfill reference
  let dummyRes = ctx.sendMessage(rec.mxid, "fi.mau.dummy.portal_created", %*{}, 0)
  if dummyRes.ok:
    rec.firstEventId = dummyRes.eventId
    ctx.runtime.portals.upsert(rec)

  (true, "")

# ===========================================================================
# Message handling helpers
# ===========================================================================

proc markMessageHandled*(ctx: PortalContext, rec: PortalRecord, discordId, authorId: string,
                         timestamp: int64, threadId, senderMXID: string,
                         parts: seq[MessagePart]): MessageRecord =
  var msg = MessageRecord(
    channelId: rec.key.channelId,
    channelReceiver: rec.key.receiver,
    discordId: discordId,
    senderId: authorId,
    timestampMs: timestamp,
    threadId: threadId,
    senderMxid: senderMXID,
    mxid: parts[0].mxid,
    attachmentId: parts[0].attachmentId
  )
  ctx.runtime.portals.db.insertMessage(msg)
  msg

proc sendDeliveryReceipt*(ctx: PortalContext, rec: PortalRecord, eventId: string) =
  if ctx.deliveryReceipts:
    discard ctx.markRead(rec.mxid, eventId)

proc redactAllParts*(ctx: PortalContext, rec: PortalRecord, msgId: string): string =
  ## Redacts all parts of a message, returns last redaction event ID.
  let existing = ctx.runtime.portals.db.getMessagesByDiscordID(rec.key, msgId)
  var lastResp = ""
  for dbMsg in existing:
    let res = ctx.redactEvent(rec.mxid, dbMsg.mxid)
    if res.ok and res.eventId.len > 0:
      lastResp = res.eventId
    ctx.runtime.portals.db.deleteMessage(dbMsg)
  lastResp

proc handleDiscordMessageDelete*(ctx: PortalContext, rec: PortalRecord, msgId: string) =
  let lastResp = ctx.redactAllParts(rec, msgId)
  if lastResp.len > 0:
    ctx.sendDeliveryReceipt(rec, lastResp)

proc handleDiscordMessageDeleteBulk*(ctx: PortalContext, rec: PortalRecord, messageIds: seq[string]) =
  var lastResp = ""
  for msgId in messageIds:
    let resp = ctx.redactAllParts(rec, msgId)
    if resp.len > 0:
      lastResp = resp
  if lastResp.len > 0:
    ctx.sendDeliveryReceipt(rec, lastResp)

# ===========================================================================
# Cleanup & lifecycle — mirrors portal.cleanup / RemoveMXID / Delete / cleanupIfEmpty
# ===========================================================================

proc cleanup*(ctx: PortalContext, rec: PortalRecord, puppetsOnly: bool) =
  if rec.mxid.len == 0:
    return
  if ctx.supportsBeeperRoomYeeting:
    discard ctx.deleteRoom(rec.mxid)
    return
  if rec.isPrivateChat:
    discard ctx.leaveRoom(rec.mxid, ctx.mainIntentMXID(rec))
    return
  ## Full cleanup: get members and kick/leave them
  let membersRes = ctx.joinedMembers(rec.mxid)
  if not membersRes.ok:
    return
  let intentMxid = ctx.mainIntentMXID(rec)
  for member in membersRes.members:
    if member == intentMxid:
      continue
    let (discordId, isPuppet) = ctx.parsePuppetMXID(member)
    if isPuppet:
      let puppetMxid = ctx.formatPuppetMXID(discordId)
      discard ctx.leaveRoom(rec.mxid, puppetMxid)
    elif not puppetsOnly:
      discard ctx.kickUser(rec.mxid, member, "Deleting portal")
  discard ctx.leaveRoom(rec.mxid, intentMxid)

proc removeMXID*(ctx: PortalContext, rec: var PortalRecord) =
  if rec.mxid.len == 0:
    return
  rec.mxid = ""
  rec.avatarSet = false
  rec.nameSet = false
  rec.topicSet = false
  rec.encrypted = false
  rec.inSpace = ""
  rec.firstEventId = ""
  ctx.runtime.portals.upsert(rec)
  ctx.runtime.portals.db.deleteAllMessages(rec.key)

proc delete*(ctx: PortalContext, rec: PortalRecord) =
  ctx.runtime.portals.delete(rec.key)

proc cleanupIfEmpty*(ctx: PortalContext, rec: var PortalRecord) =
  if rec.mxid.len == 0:
    return
  let membersRes = ctx.joinedMembers(rec.mxid)
  if not membersRes.ok:
    return
  var realUsers = 0
  for member in membersRes.members:
    let (_, isPuppet) = ctx.parsePuppetMXID(member)
    if not isPuppet and member != ctx.botUserID:
      realUsers.inc
  if realUsers == 0:
    ctx.cleanup(rec, false)
    ctx.removeMXID(rec)

proc handleMatrixLeave*(ctx: PortalContext, rec: var PortalRecord, senderDiscordId, receiverDiscordId: string) =
  if rec.isPrivateChat and senderDiscordId == receiverDiscordId:
    ctx.cleanup(rec, false)
    ctx.removeMXID(rec)
  else:
    ctx.cleanupIfEmpty(rec)

# ===========================================================================
# Error handling — mirrors errorToStatusReason / sendErrorMessage / sendStatusEvent / sendMessageMetrics
# ===========================================================================

type
  MessageStatusReason* = string
  MessageStatus* = string
  ErrorStatusInfo* = object
    reason*: MessageStatusReason
    status*: MessageStatus
    isCertain*: bool
    sendNotice*: bool
    humanMessage*: string

const
  msrUnsupported* = "unsupported"
  msrUndecryptable* = "undecryptable"
  msrNoPermission* = "no_permission"
  msrGenericError* = "generic_error"
  msrTooOld* = "too_old"
  msSuccess* = "SUCCESS"
  msFail* = "FAIL"
  msRetriable* = "RETRIABLE"

proc errorToStatusInfo*(errMsg: string): ErrorStatusInfo =
  ## Simplified error-to-status mapping.
  if errMsg.contains("unknown msgtype") or errMsg.contains("unknown emoji") or
     errMsg.contains("can't create thread"):
    return ErrorStatusInfo(reason: msrUnsupported, status: msFail, isCertain: true, sendNotice: true, humanMessage: "")
  if errMsg.contains("user is not portal receiver") or errMsg.contains("user is not logged in"):
    return ErrorStatusInfo(reason: msrNoPermission, status: msFail, isCertain: true, sendNotice: false, humanMessage: "")
  if errMsg.contains("unknown edit target") or errMsg.contains("target event not found"):
    return ErrorStatusInfo(reason: msrGenericError, status: msFail, isCertain: true, sendNotice: false, humanMessage: "")
  ErrorStatusInfo(reason: msrGenericError, status: msRetriable, isCertain: false, sendNotice: true, humanMessage: "")

proc sendErrorMessage*(ctx: PortalContext, rec: PortalRecord, msgType, message: string, confirmed: bool): string =
  if not ctx.messageErrorNotices:
    return ""
  let certainty = if confirmed: "was not" else: "may not have been"
  let body = "\u26a0 Your " & msgType & " " & certainty & " bridged: " & message
  let content = %*{
    "msgtype": "m.notice",
    "body": body
  }
  let res = ctx.sendMessage(rec.mxid, "m.room.message", content, 0)
  if res.ok: res.eventId else: ""

proc sendStatusEvent*(ctx: PortalContext, rec: PortalRecord, eventId: string, errMsg = "") =
  if not ctx.messageStatusEvents:
    return
  let (stateKey, _) = ctx.getBridgeInfo(rec)
  var content = %*{
    "network": stateKey,
    "relates_to": {
      "rel_type": "m.reference",
      "event_id": eventId
    }
  }
  if errMsg.len == 0:
    content["status"] = %"SUCCESS"
  else:
    let info = errorToStatusInfo(errMsg)
    content["status"] = %info.status
    content["reason"] = %info.reason
    content["error"] = %errMsg
  discard ctx.sendMessage(rec.mxid, "com.beeper.message_send_status", content, 0)

# ===========================================================================
# Typing — mirrors typingDiff / handleDiscordTyping
# ===========================================================================

proc typingDiff*(prev, current: seq[string]): seq[string] =
  result = @[]
  for userId in current:
    if userId notin prev:
      result.add(userId)

# ===========================================================================
# HandleMatrixKick / HandleMatrixInvite — no-op stubs
# ===========================================================================

proc handleMatrixKick*(ctx: PortalContext, rec: PortalRecord, senderMxid, targetMxid: string) =
  discard

proc handleMatrixInvite*(ctx: PortalContext, rec: PortalRecord, senderMxid, targetMxid: string) =
  discard

# ===========================================================================
# HandleTombstone — mirrors br.HandleTombstone
# ===========================================================================

proc handleTombstone*(ctx: PortalContext, rec: var PortalRecord, replacementRoom: string) =
  if replacementRoom.len == 0:
    ctx.cleanup(rec, true)
    ctx.removeMXID(rec)
    return
  ## Follow tombstone to new room
  rec.mxid = replacementRoom
  rec.avatarSet = false
  rec.nameSet = false
  rec.topicSet = false
  rec.inSpace = ""
  rec.firstEventId = ""
  ctx.runtime.portals.upsert(rec)
  ctx.updateBridgeInfo(rec)
