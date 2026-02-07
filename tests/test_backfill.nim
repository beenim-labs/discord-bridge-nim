## Tests for backfill.nim — Backfill & history sync.
## Covers: message ID comparison, should backfill, deterministic event IDs,
## message sorting, collect messages, convert batch, backfill limited/unlimited,
## forwardBackfillInitial/Missed, batch send dispatching.

import std/[unittest, options, sequtils, strutils]
import database/database
import config/config
import bridge/runtime
import bridge/portal
import bridge/portal_convert
import bridge/backfill

# ===========================================================================
# Helpers
# ===========================================================================

proc setupBackfillContext(): BackfillContext =
  let cfg = defaultConfig()
  let db = openBridgeDb(":memory:", "sqlite3")
  let rt = newDiscordBridgeRuntime(cfg, db)
  let portalCtx = newPortalContext(rt, cfg)
  portalCtx.copyAttachment = proc(url: string, encrypt: bool, id: string): PortalCopyAttachmentResult =
    PortalCopyAttachmentResult(ok: true, mxc: "mxc://example.com/" & id, mimeType: "image/png", size: 100)
  result = newBackfillContext(portalCtx)
  result.channelId = "123456789"
  result.roomMxid = "!room:example.com"

proc makeMsg(id: string, content: string = ""): DiscordMessage =
  DiscordMessage(id: id, content: content, author: DiscordUser(id: "author1", username: "Tester"))

# ===========================================================================
suite "compareMessageIDs":
# ===========================================================================

  test "equal IDs return 0":
    check compareMessageIDs("123", "123") == 0

  test "shorter ID is less":
    check compareMessageIDs("12", "123") == -1

  test "longer ID is greater":
    check compareMessageIDs("1234", "123") == 1

  test "same length lexicographic less":
    check compareMessageIDs("123", "124") == -1

  test "same length lexicographic greater":
    check compareMessageIDs("124", "123") == 1

  test "real snowflake IDs compare correctly":
    check compareMessageIDs("1234567890123456789", "1234567890123456790") == -1
    check compareMessageIDs("1234567890123456790", "1234567890123456789") == 1

  test "empty IDs are equal":
    check compareMessageIDs("", "") == 0

# ===========================================================================
suite "shouldBackfill":
# ===========================================================================

  test "server has newer messages":
    check shouldBackfill("100", "200") == true

  test "server has same message":
    check shouldBackfill("100", "100") == false

  test "server has older messages":
    check shouldBackfill("200", "100") == false

  test "longer server ID means newer":
    check shouldBackfill("99", "100") == true

# ===========================================================================
suite "deterministicEventID":
# ===========================================================================

  test "produces dollar-prefixed event ID":
    let evtId = deterministicEventID("!room:example.com", "msg1", "")
    check evtId.len > 0
    check evtId[0] == '$'
    check ":discord.com" in evtId

  test "different partName produces different ID":
    let id1 = deterministicEventID("!room:example.com", "msg1", "")
    let id2 = deterministicEventID("!room:example.com", "msg1", "att1")
    check id1 != id2

  test "deterministic — same input same output":
    let id1 = deterministicEventID("!room:example.com", "msg1", "part")
    let id2 = deterministicEventID("!room:example.com", "msg1", "part")
    check id1 == id2

  test "different rooms produce different IDs":
    let id1 = deterministicEventID("!room1:example.com", "msg1", "")
    let id2 = deterministicEventID("!room2:example.com", "msg1", "")
    check id1 != id2

# ===========================================================================
suite "sortMessagesByID":
# ===========================================================================

  test "sorts ascending by snowflake":
    var msgs = @[makeMsg("300"), makeMsg("100"), makeMsg("200")]
    sortMessagesByID(msgs)
    check msgs[0].id == "100"
    check msgs[1].id == "200"
    check msgs[2].id == "300"

  test "already sorted stays same":
    var msgs = @[makeMsg("10"), makeMsg("20"), makeMsg("30")]
    sortMessagesByID(msgs)
    check msgs[0].id == "10"
    check msgs[2].id == "30"

  test "single element":
    var msgs = @[makeMsg("1")]
    sortMessagesByID(msgs)
    check msgs[0].id == "1"

  test "empty seq":
    var msgs: seq[DiscordMessage] = @[]
    sortMessagesByID(msgs)
    check msgs.len == 0

# ===========================================================================
suite "collectBackfillMessages":
# ===========================================================================

  test "collects all when under limit":
    let ctx = setupBackfillContext()
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      # Return less than chunk size to indicate end
      (@[makeMsg("1"), makeMsg("2"), makeMsg("3")], "")
    let res = collectBackfillMessages(ctx, 10, "", none(BackfillThread))
    check res.err == ""
    check res.messages.len == 3

  test "stops at limit":
    let ctx = setupBackfillContext()
    var callCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      callCount.inc
      # Return exactly chunk size to trigger pagination
      var msgs: seq[DiscordMessage] = @[]
      for i in 0 ..< messageFetchChunkSize:
        msgs.add(makeMsg($((callCount - 1) * messageFetchChunkSize + i + 100)))
      (msgs, "")
    let res = collectBackfillMessages(ctx, 5, "", none(BackfillThread))
    check res.err == ""
    check res.messages.len == 5

  test "stops at until ID":
    let ctx = setupBackfillContext()
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("300"), makeMsg("200"), makeMsg("100")], "")
    let res = collectBackfillMessages(ctx, 100, "200", none(BackfillThread))
    check res.err == ""
    check res.foundAll == true
    check res.messages.len == 1  # only "300" is newer than "200"

  test "propagates fetch error":
    let ctx = setupBackfillContext()
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[], "network error")
    let res = collectBackfillMessages(ctx, 10, "", none(BackfillThread))
    check res.err == "network error"
    check res.messages.len == 0

  test "uses thread ID when thread provided":
    let ctx = setupBackfillContext()
    var usedChannelId = ""
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      usedChannelId = channelId
      (@[makeMsg("1")], "")
    let thread = some(BackfillThread(id: "thread_123"))
    discard collectBackfillMessages(ctx, 10, "", thread)
    check usedChannelId == "thread_123"

# ===========================================================================
suite "convertMessageBatch":
# ===========================================================================

  test "converts messages to events":
    let ctx = setupBackfillContext()
    let msgs = @[makeMsg("1", "hello"), makeMsg("2", "world")]
    let batch = convertMessageBatch(ctx, msgs, none(BackfillThread))
    check batch.events.len >= 2

  test "first part gets blank partName (deterministic ID)":
    let ctx = setupBackfillContext()
    let msgs = @[makeMsg("1", "text")]
    let batch = convertMessageBatch(ctx, msgs, none(BackfillThread))
    check batch.events.len == 1
    # The event ID should be based on blank partName for first part
    let expected = deterministicEventID(ctx.roomMxid, "1", "")
    check batch.events[0].eventId == expected

  test "empty messages produce empty batch":
    let ctx = setupBackfillContext()
    let batch = convertMessageBatch(ctx, @[], none(BackfillThread))
    check batch.events.len == 0

  test "uses thread last message from getLastMessage":
    let ctx = setupBackfillContext()
    ctx.getLastMessage = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] =
      if threadId == "t1": (true, "last_msg", "$last:example.com")
      else: (false, "", "")
    let thread = some(BackfillThread(id: "t1", rootMxid: "$root:example.com"))
    let msgs = @[makeMsg("1", "in-thread")]
    let batch = convertMessageBatch(ctx, msgs, thread)
    check batch.events.len >= 1

# ===========================================================================
suite "sendBackfillBatch":
# ===========================================================================

  test "uses batch send when supported":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = true
    var batchSentCount = 0
    ctx.batchSend = proc(roomMxid: string, events: seq[ConvertedBatchEvent]): tuple[eventIds: seq[string], err: string] =
      batchSentCount = events.len
      (events.mapIt(it.eventId), "")
    var massInserted = false
    ctx.massInsert = proc(messages: seq[ConvertedBatchEvent]) =
      massInserted = true
    let msgs = @[makeMsg("1", "hello")]
    sendBackfillBatch(ctx, msgs, none(BackfillThread))
    check batchSentCount >= 1
    check massInserted

  test "uses handleMessageCreate when batch not supported":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = false
    var handledCount = 0
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    let msgs = @[makeMsg("1", "hello"), makeMsg("2", "world")]
    sendBackfillBatch(ctx, msgs, none(BackfillThread))
    check handledCount == 2

  test "empty messages do nothing with batch send":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = true
    var batchCalled = false
    ctx.batchSend = proc(roomMxid: string, events: seq[ConvertedBatchEvent]): tuple[eventIds: seq[string], err: string] =
      batchCalled = true
      (@[], "")
    sendBackfillBatch(ctx, @[], none(BackfillThread))
    check not batchCalled  # batch.events is empty, so batchSend not called

# ===========================================================================
suite "backfillLimited":
# ===========================================================================

  test "collects and sends messages":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = false
    var handledIds: seq[string] = @[]
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("3"), makeMsg("1"), makeMsg("2")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledIds.add(msg.id)
    backfillLimited(ctx, 10, "", none(BackfillThread))
    check handledIds.len == 3
    # Should be sorted
    check handledIds[0] == "1"
    check handledIds[1] == "2"
    check handledIds[2] == "3"

  test "sends warning when not all found":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = false
    var warningSent = false
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("300"), makeMsg("200")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) = discard
    ctx.sendWarning = proc(roomMxid, body: string): string =
      warningSent = true
      ""
    # after="100" means we're looking for messages after ID 100
    # but collectBackfillMessages with until="100" should find both.
    # Actually "300" > "200" > "100", so both are newer — foundAll depends on until logic.
    # With 2 msgs returned (< chunk size), loop ends. until="100": 300>100 ok, 200>100 ok, so no truncation.
    # foundAll stays false (initial value). With after="100", warning should be sent.
    backfillLimited(ctx, 10, "100", none(BackfillThread))
    check warningSent

  test "does not send warning on initial backfill (after is empty)":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = false
    var warningSent = false
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("1")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) = discard
    ctx.sendWarning = proc(roomMxid, body: string): string =
      warningSent = true
      ""
    backfillLimited(ctx, 10, "", none(BackfillThread))
    check not warningSent

# ===========================================================================
suite "backfillUnlimitedMissed":
# ===========================================================================

  test "fetches chunks until less than chunk size":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = false
    var fetchCount = 0
    var handledCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      fetchCount.inc
      if fetchCount == 1:
        # Return exactly chunk size to trigger another fetch
        var msgs: seq[DiscordMessage] = @[]
        for i in 0 ..< messageFetchChunkSize:
          msgs.add(makeMsg($(i + 100)))
        (msgs, "")
      else:
        # Return less than chunk size to stop
        (@[makeMsg("200"), makeMsg("201")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    backfillUnlimitedMissed(ctx, "50", none(BackfillThread))
    check fetchCount == 2
    check handledCount == messageFetchChunkSize + 2

  test "stops on fetch error":
    let ctx = setupBackfillContext()
    ctx.supportsBatchSend = false
    var handledCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[], "connection lost")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    backfillUnlimitedMissed(ctx, "50", none(BackfillThread))
    check handledCount == 0

# ===========================================================================
suite "forwardBackfillInitial":
# ===========================================================================

  test "uses channel limit for guild portals":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.initial.channelLimit = 5
    ctx.supportsBatchSend = false
    var handledCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      var msgs: seq[DiscordMessage] = @[]
      for i in 0 ..< 3:
        msgs.add(makeMsg($(i + 1)))
      (msgs, "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    var thread = none(BackfillThread)
    forwardBackfillInitial(ctx, thread)
    check handledCount == 3

  test "uses DM limit for non-guild portals":
    let ctx = setupBackfillContext()
    ctx.guildId = ""
    ctx.backfillConfig.initial.dmLimit = 2
    ctx.supportsBatchSend = false
    var handledCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      var msgs: seq[DiscordMessage] = @[]
      for i in 0 ..< 5:
        msgs.add(makeMsg($(i + 1)))
      (msgs, "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    var thread = none(BackfillThread)
    forwardBackfillInitial(ctx, thread)
    check handledCount == 2

  test "zero limit does nothing":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.initial.channelLimit = 0
    var handledCount = 0
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    var thread = none(BackfillThread)
    forwardBackfillInitial(ctx, thread)
    check handledCount == 0

  test "thread sets initialBackfillAttempted":
    let ctx = setupBackfillContext()
    ctx.guildId = ""
    ctx.backfillConfig.initial.threadLimit = 5
    ctx.supportsBatchSend = false
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("1")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) = discard
    var thread = some(BackfillThread(id: "t1"))
    forwardBackfillInitial(ctx, thread)
    check thread.get().initialBackfillAttempted == true

# ===========================================================================
suite "forwardBackfillMissed":
# ===========================================================================

  test "skips if no room MXID":
    let ctx = setupBackfillContext()
    ctx.roomMxid = ""
    var handledCount = 0
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    forwardBackfillMissed(ctx, "100", none(BackfillThread))
    check handledCount == 0

  test "skips if zero limit":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.missed.channelLimit = 0
    var handledCount = 0
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    forwardBackfillMissed(ctx, "100", none(BackfillThread))
    check handledCount == 0

  test "skips if no last message in database":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.missed.channelLimit = 10
    ctx.getLastMessage = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] =
      (false, "", "")
    var handledCount = 0
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    forwardBackfillMissed(ctx, "100", none(BackfillThread))
    check handledCount == 0

  test "skips if already up to date":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.missed.channelLimit = 10
    ctx.getLastMessage = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] =
      (true, "200", "$evt:example.com")
    var handledCount = 0
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    forwardBackfillMissed(ctx, "100", none(BackfillThread))  # server is older
    check handledCount == 0

  test "backfills when server has newer messages":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.missed.channelLimit = 10
    ctx.supportsBatchSend = false
    ctx.getLastMessage = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] =
      (true, "100", "$evt:example.com")
    var handledCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("200"), makeMsg("150")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    forwardBackfillMissed(ctx, "300", none(BackfillThread))
    check handledCount == 2

  test "uses unlimited backfill for negative limit":
    let ctx = setupBackfillContext()
    ctx.guildId = "guild1"
    ctx.backfillConfig.missed.channelLimit = -1
    ctx.supportsBatchSend = false
    ctx.getLastMessage = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] =
      (true, "100", "$evt:example.com")
    var handledCount = 0
    ctx.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
      (@[makeMsg("200")], "")
    ctx.handleMessageCreate = proc(msg: DiscordMessage) =
      handledCount.inc
    forwardBackfillMissed(ctx, "300", none(BackfillThread))
    check handledCount == 1

# ===========================================================================
suite "BackfillContext construction":
# ===========================================================================

  test "default stubs return errors/no-ops":
    let ctx = setupBackfillContext()
    let fetchResult = ctx.fetchMessages("ch", 10, "", "")
    check fetchResult.err == "fetch not configured"
    let batchResult = ctx.batchSend("!room", @[])
    check batchResult.err == "batch send not configured"
    let lastMsg = ctx.getLastMessage("ch", "")
    check lastMsg.found == false
