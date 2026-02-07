import std/[unittest, json, strutils, times]
import database/[database, entities, store]
import config/config
import bridge/[runtime, portal]

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

var testDbCounter = 0

proc testCtx(): PortalContext =
  testDbCounter.inc
  let dbPath = "tests/fixtures/portal-test-" & $getTime().toUnix() & "-" & $testDbCounter & ".db"
  let db = openBridgeDb("file:" & dbPath, "sqlite")
  let cfg = defaultConfig()
  let rt = newDiscordBridgeRuntime(cfg, db)
  result = newPortalContext(rt, cfg)
  result.botUserID = "@discordbot:example.com"
  result.homeserverDomain = "example.com"
  result.privateChatPortalMeta = "always"

proc testRec(channelId = "1234", receiver = "", portalType = 0, mxid = ""): PortalRecord =
  newPortalRecord(PortalKey(channelId: channelId, receiver: receiver), portalType)

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

suite "portal layer":

  # -- Lookup helpers --

  test "isPrivateChat":
    var dm = testRec(portalType = channelTypeDM)
    check dm.isPrivateChat
    var group = testRec(portalType = channelTypeGroupDM)
    check not group.isPrivateChat
    var guild = testRec(portalType = 0)
    check not guild.isPrivateChat

  test "mainIntentMXID bot for non-DM":
    let ctx = testCtx()
    var rec = testRec(portalType = 0)
    check ctx.mainIntentMXID(rec) == "@discordbot:example.com"

  test "mainIntentMXID puppet for DM":
    let ctx = testCtx()
    var rec = testRec(portalType = channelTypeDM)
    rec.otherUserId = "99887766"
    check "99887766" in ctx.mainIntentMXID(rec)

  test "shouldSetDMRoomMetadata always":
    let ctx = testCtx()
    ctx.privateChatPortalMeta = "always"
    var rec = testRec(portalType = channelTypeDM)
    check ctx.shouldSetDMRoomMetadata(rec)

  test "shouldSetDMRoomMetadata never for unencrypted DM":
    let ctx = testCtx()
    ctx.privateChatPortalMeta = "never"
    var rec = testRec(portalType = channelTypeDM)
    rec.encrypted = false
    check not ctx.shouldSetDMRoomMetadata(rec)

  test "shouldSetDMRoomMetadata true for non-DM":
    let ctx = testCtx()
    ctx.privateChatPortalMeta = "never"
    var rec = testRec(portalType = 0)
    check ctx.shouldSetDMRoomMetadata(rec)

  # -- Helpers --

  test "generateNonce is non-empty":
    let n = generateNonce()
    check n.len > 0

  test "cutBody truncates at max chars":
    let longBody = 'x'.repeat(100)
    let cutResult = cutBody(longBody)
    check cutResult.len <= 72 + "…".len

  test "cutBody truncates at max lines":
    let body = "line1\nline2\nline3"
    let cutResult = cutBody(body)
    check "line1" in cutResult
    check "[…]" in cutResult

  test "genThreadName uses first words":
    check genThreadName("hello world this is a test") == "hello world this is a test "

  test "genThreadName empty body":
    check genThreadName("") == "thread"

  test "genThreadName long single word":
    let long = 'a'.repeat(60)
    let genResult = genThreadName(long)
    check genResult.len <= 40

  # -- Bridge info --

  test "getBridgeInfo DM":
    let ctx = testCtx()
    var rec = testRec(portalType = channelTypeDM)
    rec.name = "Test DM"
    let (stateKey, content) = ctx.getBridgeInfo(rec)
    check stateKey.find("fi.mau.discord://discord/dm/") == 0
    check content["channel"]["id"].getStr() == "1234"
    check content["channel"]["displayname"].getStr() == "Test DM"
    check "com.beeper.room_type" in content
    check content["com.beeper.room_type"].getStr() == "dm"

  test "getBridgeInfo guild":
    let ctx = testCtx()
    var rec = testRec(portalType = 0)
    rec.guildId = "guild123"
    rec.name = "General"
    let (stateKey, content) = ctx.getBridgeInfo(rec)
    check stateKey.find("guild123") >= 0
    check content.hasKey("network")
    check content["network"]["id"].getStr() == "guild123"

  test "updateBridgeInfo no-op when no mxid":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = ""
    var called = false
    ctx.sendStateEvent = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult =
      called = true
      (true, "", "")
    ctx.updateBridgeInfo(rec)
    check not called

  test "updateBridgeInfo calls when mxid set":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!room:example.com"
    rec.name = "Test"
    var calls = 0
    ctx.sendStateEvent = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult =
      calls.inc
      (true, "", "")
    ctx.updateBridgeInfo(rec)
    check calls == 2  # m.bridge + uk.half-shot.bridge

  # -- Encryption --

  test "isEncrypted and markEncrypted":
    let ctx = testCtx()
    var rec = testRec()
    ctx.runtime.portals.upsert(rec)
    check not rec.isEncrypted
    ctx.markEncrypted(rec)
    check rec.isEncrypted

  # -- Name updates --

  test "updateNameDirect changes name":
    let ctx = testCtx()
    var rec = testRec()
    rec.name = "Old"
    rec.nameSet = false
    let changed = ctx.updateNameDirect(rec, "New", false)
    check changed
    check rec.name == "New"

  test "updateNameDirect no-op when same":
    let ctx = testCtx()
    var rec = testRec()
    rec.name = "Same"
    rec.nameSet = true
    let changed = ctx.updateNameDirect(rec, "Same", false)
    check not changed

  test "updateNameDirect friend nick priority":
    let ctx = testCtx()
    var rec = testRec()
    rec.friendNick = true
    rec.name = "FriendName"
    let changed = ctx.updateNameDirect(rec, "NotFriend", false)
    check not changed  # friendNick blocks non-friend name updates
    check rec.name == "FriendName"

  test "updateRoomName calls setRoomName":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!room:example.com"
    rec.name = "TestRoom"
    var calledName = ""
    ctx.setRoomName = proc(roomId, name: string): PortalSetRoomNameResult =
      calledName = name
      (true, "")
    ctx.updateRoomName(rec)
    check calledName == "TestRoom"
    check rec.nameSet

  # -- Avatar updates --

  test "updateAvatarFromPuppet changes avatar":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!room:example.com"
    rec.avatar = "old"
    rec.avatarUrl = "mxc://old"
    rec.avatarSet = true
    let changed = ctx.updateAvatarFromPuppet(rec, "new", "mxc://new")
    check changed
    check rec.avatar == "new"
    check rec.avatarUrl == "mxc://new"

  test "updateAvatarFromPuppet no-op when same":
    let ctx = testCtx()
    var rec = testRec()
    rec.avatar = "same"
    rec.avatarUrl = "mxc://same"
    rec.avatarSet = true
    let changed = ctx.updateAvatarFromPuppet(rec, "same", "mxc://same")
    check not changed

  # -- Topic updates --

  test "updateTopic changes topic":
    let ctx = testCtx()
    var rec = testRec()
    rec.topic = "old topic"
    rec.topicSet = false
    let changed = ctx.updateTopic(rec, "new topic")
    check changed
    check rec.topic == "new topic"

  test "updateTopic no-op when same and set":
    let ctx = testCtx()
    var rec = testRec()
    rec.topic = "same"
    rec.topicSet = true
    let changed = ctx.updateTopic(rec, "same")
    check not changed

  # -- Space management --

  test "addToSpace sets inSpace":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!room:example.com"
    var stateEvents: seq[tuple[roomId, eventType, stateKey: string]] = @[]
    ctx.sendStateEvent = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult =
      stateEvents.add((roomId, eventType, stateKey))
      (true, "", "")
    let changed = ctx.addToSpace(rec, "!space:example.com")
    check changed
    check rec.inSpace == "!space:example.com"
    check stateEvents.len == 2

  test "addToSpace no-op when same":
    let ctx = testCtx()
    var rec = testRec()
    rec.inSpace = "!space:example.com"
    let changed = ctx.addToSpace(rec, "!space:example.com")
    check not changed

  test "removeFromSpace clears inSpace":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!room:example.com"
    rec.inSpace = "!space:example.com"
    var calls = 0
    ctx.sendStateEvent = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult =
      calls.inc
      (true, "", "")
    ctx.removeFromSpace(rec)
    check rec.inSpace == ""
    check calls == 2

  test "updateParent changes parentId":
    let ctx = testCtx()
    var rec = testRec()
    rec.parentId = "old"
    let changed = ctx.updateParent(rec, "new")
    check changed
    check rec.parentId == "new"

  test "updateParent no-op when same":
    let ctx = testCtx()
    var rec = testRec()
    rec.parentId = "same"
    let changed = ctx.updateParent(rec, "same")
    check not changed

  # -- UpdateInfo --

  test "updateInfo changes type":
    let ctx = testCtx()
    var rec = testRec(portalType = 0)
    ctx.runtime.portals.upsert(rec)
    let meta = DiscordChannel(chanType: channelTypeGroupDM, name: "TestGroup", topic: "t")
    let changed = ctx.updateInfo(rec, meta)
    check changed
    check rec.portalType == channelTypeGroupDM

  test "updateInfo sets otherUserId for DM":
    let ctx = testCtx()
    var rec = testRec(portalType = channelTypeDM)
    ctx.runtime.portals.upsert(rec)
    let meta = DiscordChannel(chanType: channelTypeDM, recipients: @[DiscordChannelRecipient(id: "user555")])
    let changed = ctx.updateInfo(rec, meta)
    check changed
    check rec.otherUserId == "user555"

  # -- CreateMatrixRoom --

  test "createMatrixRoom already exists":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!existing:example.com"
    let meta = DiscordChannel()
    let res = ctx.createMatrixRoom(rec, meta)
    check res.ok

  test "createMatrixRoom creates room":
    let ctx = testCtx()
    var rec = testRec()
    ctx.runtime.portals.upsert(rec)
    ctx.createRoom = proc(req: JsonNode): PortalCreateRoomResult =
      (true, "!new:example.com", "")
    ctx.sendMessage = proc(roomId, eventType: string, content: JsonNode, timestamp: int64): PortalSendMessageResult =
      (true, "$dummy:example.com", "")
    let meta = DiscordChannel(name: "Test")
    let res = ctx.createMatrixRoom(rec, meta)
    check res.ok
    check rec.mxid == "!new:example.com"

  test "createMatrixRoom fails gracefully":
    let ctx = testCtx()
    var rec = testRec()
    ctx.runtime.portals.upsert(rec)
    ctx.createRoom = proc(req: JsonNode): PortalCreateRoomResult =
      (false, "", "room creation failed")
    let meta = DiscordChannel()
    let res = ctx.createMatrixRoom(rec, meta)
    check not res.ok
    check res.err.find("room creation failed") >= 0

  # -- Message handling --

  test "markMessageHandled inserts message":
    let ctx = testCtx()
    var rec = testRec()
    ctx.runtime.portals.upsert(rec)
    let parts = @[MessagePart(attachmentId: "att1", mxid: "$evt1")]
    let msg = ctx.markMessageHandled(rec, "discord123", "author1", 1000, "", "sender_mxid", parts)
    check msg.discordId == "discord123"
    check msg.mxid == "$evt1"

  test "sendDeliveryReceipt calls markRead":
    let ctx = testCtx()
    ctx.deliveryReceipts = true
    var calledEventId = ""
    ctx.markRead = proc(roomId, eventId: string): PortalMarkReadResult =
      calledEventId = eventId
      (true, "")
    var rec = testRec()
    rec.mxid = "!room:example.com"
    ctx.sendDeliveryReceipt(rec, "$evt1")
    check calledEventId == "$evt1"

  test "sendDeliveryReceipt no-op when disabled":
    let ctx = testCtx()
    ctx.deliveryReceipts = false
    var called = false
    ctx.markRead = proc(roomId, eventId: string): PortalMarkReadResult =
      called = true
      (true, "")
    var rec = testRec()
    ctx.sendDeliveryReceipt(rec, "$evt1")
    check not called

  # -- Cleanup / lifecycle --

  test "removeMXID clears metadata":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!room:example.com"
    rec.avatarSet = true
    rec.nameSet = true
    rec.topicSet = true
    rec.encrypted = true
    rec.inSpace = "!space:example.com"
    rec.firstEventId = "$first"
    ctx.runtime.portals.upsert(rec)
    ctx.removeMXID(rec)
    check rec.mxid == ""
    check not rec.avatarSet
    check not rec.nameSet
    check not rec.topicSet
    check not rec.encrypted
    check rec.inSpace == ""
    check rec.firstEventId == ""

  test "cleanup beeper yeeting":
    let ctx = testCtx()
    ctx.supportsBeeperRoomYeeting = true
    var deletedRoom = ""
    ctx.deleteRoom = proc(roomId: string): PortalDeleteRoomResult =
      deletedRoom = roomId
      (true, "")
    var rec = testRec()
    rec.mxid = "!room:example.com"
    ctx.cleanup(rec, false)
    check deletedRoom == "!room:example.com"

  test "cleanup private chat leaves":
    let ctx = testCtx()
    ctx.supportsBeeperRoomYeeting = false
    var leftRoom = ""
    ctx.leaveRoom = proc(roomId, userId: string): PortalLeaveRoomResult =
      leftRoom = roomId
      (true, "")
    var rec = testRec(portalType = channelTypeDM)
    rec.mxid = "!room:example.com"
    ctx.cleanup(rec, false)
    check leftRoom == "!room:example.com"

  test "handleMatrixLeave DM self-leaves cleans up":
    let ctx = testCtx()
    ctx.supportsBeeperRoomYeeting = true
    var deletedRoom = ""
    ctx.deleteRoom = proc(roomId: string): PortalDeleteRoomResult =
      deletedRoom = roomId
      (true, "")
    var rec = testRec(receiver = "user1", portalType = channelTypeDM)
    rec.mxid = "!room:example.com"
    ctx.runtime.portals.upsert(rec)
    ctx.handleMatrixLeave(rec, "user1", "user1")
    check deletedRoom == "!room:example.com"

  # -- Error handling --

  test "errorToStatusInfo unsupported":
    let info = errorToStatusInfo("unknown msgtype: m.custom")
    check info.reason == msrUnsupported
    check info.status == msFail

  test "errorToStatusInfo no permission":
    let info = errorToStatusInfo("user is not logged in and portal doesn't have webhook")
    check info.reason == msrNoPermission

  test "errorToStatusInfo generic fallback":
    let info = errorToStatusInfo("some random error")
    check info.reason == msrGenericError
    check info.status == msRetriable

  test "sendErrorMessage when disabled":
    let ctx = testCtx()
    ctx.messageErrorNotices = false
    var rec = testRec()
    rec.mxid = "!room:example.com"
    let eventId = ctx.sendErrorMessage(rec, "message", "fail", true)
    check eventId == ""

  test "sendErrorMessage when enabled":
    let ctx = testCtx()
    ctx.messageErrorNotices = true
    var sentBody = ""
    ctx.sendMessage = proc(roomId, eventType: string, content: JsonNode, timestamp: int64): PortalSendMessageResult =
      sentBody = content["body"].getStr()
      (true, "$err1", "")
    var rec = testRec()
    rec.mxid = "!room:example.com"
    let eventId = ctx.sendErrorMessage(rec, "message", "fail", true)
    check eventId == "$err1"
    check sentBody.find("was not bridged") >= 0

  # -- Typing --

  test "typingDiff":
    let prev = @["a", "b", "c"]
    let current = @["b", "c", "d"]
    let started = typingDiff(prev, current)
    check started == @["d"]

  test "typingDiff all new":
    let prev: seq[string] = @[]
    let current = @["a", "b"]
    let started = typingDiff(prev, current)
    check started == @["a", "b"]

  # -- Tombstone --

  test "handleTombstone empty replacement cleans up":
    let ctx = testCtx()
    ctx.supportsBeeperRoomYeeting = true
    var deletedRoom = ""
    ctx.deleteRoom = proc(roomId: string): PortalDeleteRoomResult =
      deletedRoom = roomId
      (true, "")
    var rec = testRec()
    rec.mxid = "!room:example.com"
    ctx.runtime.portals.upsert(rec)
    ctx.handleTombstone(rec, "")
    check deletedRoom == "!room:example.com"

  test "handleTombstone follows to new room":
    let ctx = testCtx()
    var rec = testRec()
    rec.mxid = "!old:example.com"
    rec.avatarSet = true
    rec.nameSet = true
    ctx.runtime.portals.upsert(rec)
    var bridgeInfoCalls = 0
    ctx.sendStateEvent = proc(roomId, eventType, stateKey: string, content: JsonNode): PortalSendStateEventResult =
      bridgeInfoCalls.inc
      (true, "", "")
    ctx.handleTombstone(rec, "!new:example.com")
    check rec.mxid == "!new:example.com"
    check not rec.avatarSet
    check not rec.nameSet
    check bridgeInfoCalls > 0

  # -- No-op stubs --

  test "handleMatrixKick is no-op":
    let ctx = testCtx()
    var rec = testRec()
    ctx.handleMatrixKick(rec, "@sender:example.com", "@target:example.com")

  test "handleMatrixInvite is no-op":
    let ctx = testCtx()
    var rec = testRec()
    ctx.handleMatrixInvite(rec, "@sender:example.com", "@target:example.com")
