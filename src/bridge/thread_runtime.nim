## Thread runtime compatibility helpers adapted from Go thread.go behavior.

import std/[tables, locks]
import database/entities
import database/store
import bridge/managers/[threads, portals]

type
  ThreadRootMessage* = object
    discordId*: string
    mxid*: string
    parentChannelId*: string

  ThreadMetadata* = object
    memberIdsPreview*: seq[string]
    messageCount*: int

  ThreadLoadResult* = object
    found*: bool
    rec*: ThreadRecord
    parentFound*: bool
    parent*: PortalRecord

  ThreadFoundResult* = object
    found*: bool
    rec*: ThreadRecord
    shouldSendCreationNotice*: bool
    markUserInPortal*: bool
    shouldInitialBackfill*: bool

  ThreadJoinResult* = object
    shouldJoin*: bool
    markPortalJoined*: bool
    doBackfill*: bool

  ThreadRuntime* = ref object
    threads*: ThreadManager
    portals*: PortalManager
    lock: Lock
    initialBackfillAttempted: Table[string, bool]

proc newThreadRuntime*(threads: ThreadManager, portals: PortalManager): ThreadRuntime =
  new(result)
  result.threads = threads
  result.portals = portals
  initLock(result.lock)
  result.initialBackfillAttempted = initTable[string, bool]()

proc containsId(items: seq[string], id: string): bool =
  for item in items:
    if item == id:
      return true
  false

proc setInitialBackfillAttempted*(rt: ThreadRuntime, threadId: string, attempted = true) =
  if rt == nil or threadId.len == 0:
    return
  withLock rt.lock:
    rt.initialBackfillAttempted[threadId] = attempted

proc isInitialBackfillAttempted*(rt: ThreadRuntime, threadId: string): bool =
  if rt == nil or threadId.len == 0:
    return false
  withLock rt.lock:
    if rt.initialBackfillAttempted.hasKey(threadId):
      return rt.initialBackfillAttempted[threadId]
  false

proc getThreadByID*(
    rt: ThreadRuntime,
    threadId: string,
    root: ThreadRootMessage = ThreadRootMessage()
): tuple[found: bool, rec: ThreadRecord] =
  if rt == nil or rt.threads == nil or threadId.len == 0:
    return (false, default(ThreadRecord))

  let existing = rt.threads.getByID(threadId)
  if existing.found:
    return existing

  if root.parentChannelId.len == 0:
    return (false, default(ThreadRecord))

  var created = newThreadRecord(threadId)
  created.rootDiscordId = root.discordId
  created.rootMxid = root.mxid
  created.parentChannelId = root.parentChannelId
  rt.threads.upsert(created)
  (true, created)

proc getThreadByRootMXID*(rt: ThreadRuntime, mxid: string): tuple[found: bool, rec: ThreadRecord] =
  if rt == nil or rt.threads == nil or mxid.len == 0:
    return (false, default(ThreadRecord))
  rt.threads.getByRootMXID(mxid)

proc getThreadByRootOrCreationNoticeMXID*(rt: ThreadRuntime, mxid: string): tuple[found: bool, rec: ThreadRecord] =
  if rt == nil or rt.threads == nil or mxid.len == 0:
    return (false, default(ThreadRecord))
  rt.threads.getByRootOrCreationNoticeMXID(mxid)

proc loadThread*(
    rt: ThreadRuntime,
    dbThread: ThreadRecord,
    hasDbThread: bool,
    threadId: string,
    root: ThreadRootMessage
): ThreadLoadResult =
  if rt == nil:
    return ThreadLoadResult(found: false)

  var rec: ThreadRecord
  if hasDbThread:
    rec = dbThread
  else:
    if root.parentChannelId.len == 0:
      return ThreadLoadResult(found: false)
    rec = newThreadRecord(threadId)
    rec.rootDiscordId = root.discordId
    rec.rootMxid = root.mxid
    rec.parentChannelId = root.parentChannelId
    rt.threads.upsert(rec)

  let parent = rt.portals.getByID(PortalKey(channelId: rec.parentChannelId, receiver: ""))
  result = ThreadLoadResult(
    found: true,
    rec: rec,
    parentFound: parent.found,
    parent: parent.rec
  )

proc threadFound*(
    rt: ThreadRuntime,
    sourceDiscordId: string,
    userAlreadyInPortal: bool,
    rootMessage: ThreadRootMessage,
    threadId: string,
    metadata: ThreadMetadata
): ThreadFoundResult =
  if rt == nil:
    return ThreadFoundResult(found: false)

  let thread = rt.getThreadByID(threadId, rootMessage)
  if not thread.found:
    return ThreadFoundResult(found: false)

  let sourceInPreview =
    sourceDiscordId.len > 0 and containsId(metadata.memberIdsPreview, sourceDiscordId)
  let markJoined = sourceInPreview and not userAlreadyInPortal
  let shouldInitialBackfill = markJoined and metadata.messageCount > 0
  if markJoined and metadata.messageCount <= 0:
    rt.setInitialBackfillAttempted(threadId, true)

  ThreadFoundResult(
    found: true,
    rec: thread.rec,
    shouldSendCreationNotice: thread.rec.creationNoticeMxid.len == 0,
    markUserInPortal: markJoined,
    shouldInitialBackfill: shouldInitialBackfill
  )

proc maybeInitialBackfill*(
    rt: ThreadRuntime,
    threadId: string,
    initialThreadLimit: int,
    hasLastThreadMessage: bool
): bool =
  if rt == nil or threadId.len == 0:
    return false
  if rt.isInitialBackfillAttempted(threadId) or initialThreadLimit == 0:
    return false
  if hasLastThreadMessage:
    return false
  rt.setInitialBackfillAttempted(threadId, true)
  true

proc refererOpt*(guildId, parentChannelId, threadId: string): string =
  ## Stand-in for discordgo.WithThreadReferer(...) arguments.
  guildId & "/" & parentChannelId & "/" & threadId

proc joinThread*(
    rt: ThreadRuntime,
    threadId: string,
    userAlreadyInPortal: bool,
    initialThreadLimit: int,
    hasLastThreadMessage: bool
): ThreadJoinResult =
  if rt == nil or threadId.len == 0 or userAlreadyInPortal:
    return ThreadJoinResult(shouldJoin: false, markPortalJoined: false, doBackfill: false)

  let doBackfill = rt.maybeInitialBackfill(threadId, initialThreadLimit, hasLastThreadMessage)
  ThreadJoinResult(
    shouldJoin: true,
    markPortalJoined: true,
    doBackfill: doBackfill
  )
