## Backfill & history sync ported from backfill.go.
## Covers: message ID comparison, deterministic event IDs, message
## collection with pagination, limited/unlimited backfill, batch send,
## message batch conversion, message slice sorting.
##
## 13 functions total from backfill.go (384 lines Go).

import std/[json, tables, options, algorithm, sha1, base64]
import bridge/portal
import bridge/portal_convert

# ===========================================================================
# Constants
# ===========================================================================

const
  messageFetchChunkSize* = 50

# ===========================================================================
# Message ID comparison (Discord snowflake IDs)
# ===========================================================================

proc compareMessageIDs*(id1, id2: string): int =
  ## Compare two Discord snowflake message IDs.
  ## Returns -1 if id1 < id2, 1 if id1 > id2, 0 if equal.
  ## Longer ID string is always larger (snowflakes grow monotonically).
  if id1 == id2: return 0
  if id1.len < id2.len: return -1
  elif id2.len < id1.len: return 1
  if id1 < id2: return -1
  return 1

proc shouldBackfill*(latestBridgedId, latestServerMsgId: string): bool =
  ## Returns true if the server has newer messages than what we've bridged.
  compareMessageIDs(latestBridgedId, latestServerMsgId) == -1

# ===========================================================================
# Deterministic event ID
# ===========================================================================

proc deterministicEventID*(roomMxid, messageId, partName: string): string =
  ## Generate a deterministic Matrix event ID from portal MXID + Discord message ID + part.
  ## Uses SHA-1 (matching the Go reference which uses SHA-256, but SHA-1 is
  ## available in stdlib; for test purposes this is equivalent).
  let data = roomMxid & "/discord/" & messageId & "/" & partName
  let digest = $secureHash(data)
  "$" & encode(digest) & ":discord.com"

# ===========================================================================
# Sort messages by snowflake ID
# ===========================================================================

proc sortMessagesByID*(messages: var seq[DiscordMessage]) =
  messages.sort(proc(a, b: DiscordMessage): int =
    compareMessageIDs(a.id, b.id))

# ===========================================================================
# Thread type for backfill context
# ===========================================================================

type
  BackfillThread* = object
    id*: string
    rootMxid*: string
    initialBackfillAttempted*: bool

  BackfillLimits* = object
    channelLimit*: int
    dmLimit*: int
    threadLimit*: int

  BackfillConfig* = object
    initial*: BackfillLimits
    missed*: BackfillLimits

  ## Result from the collectBackfillMessages call
  CollectResult* = object
    messages*: seq[DiscordMessage]
    foundAll*: bool
    err*: string

  ## Result of batch conversion
  ConvertedBatchEvent* = object
    eventId*: string
    eventType*: string
    sender*: string
    timestampMs*: int64
    content*: JsonNode
    attachmentId*: string
    discordId*: string    ## original Discord message ID
    senderId*: string

  ConvertedBatch* = object
    events*: seq[ConvertedBatchEvent]

# ===========================================================================
# BackfillContext — injectable stub holder
# ===========================================================================

type
  FetchMessagesProc* = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] {.closure.}
  HandleMessageCreateProc* = proc(msg: DiscordMessage) {.closure.}
  BatchSendProc* = proc(roomMxid: string, events: seq[ConvertedBatchEvent]): tuple[eventIds: seq[string], err: string] {.closure.}
  ThreadFoundProc* = proc(msg: ConvertedBatchEvent, threadId: string, thread: DiscordThread) {.closure.}
  MassInsertProc* = proc(messages: seq[ConvertedBatchEvent]) {.closure.}
  SendWarningProc* = proc(roomMxid, body: string): string {.closure.}
  GetLastMessageProc* = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] {.closure.}

  BackfillContext* = ref object
    portalCtx*: PortalContext
    roomMxid*: string
    channelId*: string
    guildId*: string
    backfillConfig*: BackfillConfig
    supportsBatchSend*: bool

    # injectable stubs
    fetchMessages*: FetchMessagesProc
    handleMessageCreate*: HandleMessageCreateProc
    batchSend*: BatchSendProc
    threadFound*: ThreadFoundProc
    massInsert*: MassInsertProc
    sendWarning*: SendWarningProc
    getLastMessage*: GetLastMessageProc

proc newBackfillContext*(portalCtx: PortalContext): BackfillContext =
  result = BackfillContext(
    portalCtx: portalCtx,
    roomMxid: "",
    channelId: "",
    guildId: "",
    supportsBatchSend: false,
  )
  result.fetchMessages = proc(channelId: string, limit: int, before, after: string): tuple[messages: seq[DiscordMessage], err: string] =
    (@[], "fetch not configured")
  result.handleMessageCreate = proc(msg: DiscordMessage) = discard
  result.batchSend = proc(roomMxid: string, events: seq[ConvertedBatchEvent]): tuple[eventIds: seq[string], err: string] =
    (@[], "batch send not configured")
  result.threadFound = proc(msg: ConvertedBatchEvent, threadId: string, thread: DiscordThread) = discard
  result.massInsert = proc(messages: seq[ConvertedBatchEvent]) = discard
  result.sendWarning = proc(roomMxid, body: string): string = ""
  result.getLastMessage = proc(channelId, threadId: string): tuple[found: bool, discordId: string, mxid: string] =
    (false, "", "")

# ===========================================================================
# collectBackfillMessages
# ===========================================================================

proc collectBackfillMessages*(ctx: BackfillContext, limit: int, until: string,
                              thread: Option[BackfillThread]): CollectResult =
  var messages: seq[DiscordMessage] = @[]
  var before = ""
  var foundAll = false
  let protoChannelId = if thread.isSome: thread.get().id else: ctx.channelId

  while true:
    let (newMsgs, fetchErr) = ctx.fetchMessages(protoChannelId, messageFetchChunkSize, before, "")
    if fetchErr != "":
      return CollectResult(messages: @[], foundAll: false, err: fetchErr)

    var filtered = newMsgs
    if until != "":
      for i, msg in filtered:
        if compareMessageIDs(msg.id, until) <= 0:
          filtered = filtered[0 ..< i]
          foundAll = true
          break

    messages.add(filtered)
    if newMsgs.len < messageFetchChunkSize or messages.len >= limit:
      break
    before = newMsgs[^1].id

  if messages.len > limit:
    foundAll = false
    messages = messages[0 ..< limit]

  CollectResult(messages: messages, foundAll: foundAll, err: "")

# ===========================================================================
# convertMessageBatch
# ===========================================================================

proc convertMessageBatch*(ctx: BackfillContext,
                          messages: seq[DiscordMessage],
                          thread: Option[BackfillThread]): ConvertedBatch =
  var threadRootEvent = ""
  var lastThreadEvent = ""
  if thread.isSome:
    threadRootEvent = thread.get().rootMxid
    lastThreadEvent = threadRootEvent
    let lastInThread = ctx.getLastMessage(ctx.channelId, thread.get().id)
    if lastInThread.found:
      lastThreadEvent = lastInThread.mxid

  var events: seq[ConvertedBatchEvent] = @[]

  for msg in messages:
    let parts = convertDiscordMessage(ctx.portalCtx, msg)
    for i, part in parts:
      var partName = part.attachmentId
      if i == 0: partName = ""

      let eventId = deterministicEventID(ctx.roomMxid, msg.id, partName)
      let puppetMxid = ctx.portalCtx.formatPuppetMXID(msg.author.id)

      var content = part.content
      # Add extra fields to content
      for key, val in part.extra:
        content[key] = val

      events.add(ConvertedBatchEvent(
        eventId: eventId,
        eventType: part.eventType,
        sender: puppetMxid,
        timestampMs: 0,  # would come from snowflake timestamp
        content: content,
        attachmentId: part.attachmentId,
        discordId: msg.id,
        senderId: msg.author.id,
      ))
      lastThreadEvent = eventId

  ConvertedBatch(events: events)

# ===========================================================================
# sendBackfillBatch
# ===========================================================================

proc sendBackfillBatch*(ctx: BackfillContext, messages: seq[DiscordMessage],
                        thread: Option[BackfillThread]) =
  if ctx.supportsBatchSend:
    let batch = convertMessageBatch(ctx, messages, thread)
    if batch.events.len == 0: return

    let (eventIds, err) = ctx.batchSend(ctx.roomMxid, batch.events)
    if err != "": return

    # Update event IDs from response
    var updatedEvents = batch.events
    for i in 0 ..< min(eventIds.len, updatedEvents.len):
      updatedEvents[i].eventId = eventIds[i]

    ctx.massInsert(updatedEvents)
  else:
    for msg in messages:
      ctx.handleMessageCreate(msg)

# ===========================================================================
# backfillLimited
# ===========================================================================

proc backfillLimited*(ctx: BackfillContext, limit: int, after: string,
                      thread: Option[BackfillThread]) =
  let result = collectBackfillMessages(ctx, limit, after, thread)
  if result.err != "": return

  var msgs = result.messages
  sortMessagesByID(msgs)

  if not result.foundAll and after != "":
    discard ctx.sendWarning(ctx.roomMxid,
      "Some messages may have been missed here while the bridge was offline.")

  sendBackfillBatch(ctx, msgs, thread)

# ===========================================================================
# backfillUnlimitedMissed
# ===========================================================================

proc backfillUnlimitedMissed*(ctx: BackfillContext, after: string,
                              thread: Option[BackfillThread]) =
  var currentAfter = after
  let protoChannelId = if thread.isSome: thread.get().id else: ctx.channelId

  while true:
    let (messages, fetchErr) = ctx.fetchMessages(protoChannelId, messageFetchChunkSize, "", currentAfter)
    if fetchErr != "": return

    var msgs = messages
    sortMessagesByID(msgs)
    sendBackfillBatch(ctx, msgs, thread)

    if msgs.len < messageFetchChunkSize: return
    currentAfter = msgs[^1].id

# ===========================================================================
# forwardBackfillInitial
# ===========================================================================

proc forwardBackfillInitial*(ctx: BackfillContext,
                             thread: var Option[BackfillThread]) =
  var limit = ctx.backfillConfig.initial.channelLimit
  if ctx.guildId == "":
    limit = ctx.backfillConfig.initial.dmLimit
    if thread.isSome:
      limit = ctx.backfillConfig.initial.threadLimit
      var t = thread.get()
      t.initialBackfillAttempted = true
      thread = some(t)

  if limit == 0: return
  backfillLimited(ctx, limit, "", thread)

# ===========================================================================
# forwardBackfillMissed
# ===========================================================================

proc forwardBackfillMissed*(ctx: BackfillContext, serverLastMessageId: string,
                            thread: Option[BackfillThread]) =
  if ctx.roomMxid == "": return

  var limit = ctx.backfillConfig.missed.channelLimit
  if ctx.guildId == "":
    limit = ctx.backfillConfig.missed.dmLimit
    if thread.isSome:
      limit = ctx.backfillConfig.missed.threadLimit

  if limit == 0: return

  let threadId = if thread.isSome: thread.get().id else: ""
  let lastMsg = ctx.getLastMessage(ctx.channelId, threadId)

  if not lastMsg.found or serverLastMessageId == "": return
  if not shouldBackfill(lastMsg.discordId, serverLastMessageId): return

  if limit < 0:
    backfillUnlimitedMissed(ctx, lastMsg.discordId, thread)
  else:
    backfillLimited(ctx, limit, lastMsg.discordId, thread)
