import std/[unittest, os, times]
import config/config
import database/[database, entities, store]
import bridge/[runtime, thread_runtime]

proc cleanupDb(path: string) =
  for suffix in ["", "-wal", "-shm"]:
    let p = path & suffix
    if fileExists(p):
      removeFile(p)

proc openTempDb(name: string): tuple[db: BridgeDb, path: string] =
  let dbPath = "tests/fixtures/" & name & "-" & $getTime().toUnix() & "-" & $epochTime().int64 & ".db"
  cleanupDb(dbPath)
  let db = openBridgeDb("file:" & dbPath, "sqlite")
  (db, dbPath)

suite "thread runtime":
  test "getThreadByID creates from root and resolves by root and creation notice mxid":
    let opened = openTempDb("thread-runtime-get")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)

      var parent = newPortalRecord(PortalKey(channelId: "chan-thread", receiver: ""), 0)
      parent.mxid = "!chan-thread:test"
      rt.portals.upsert(parent)

      let created = rt.threadRuntime.getThreadByID(
        "thread-1",
        ThreadRootMessage(
          discordId: "root-dcid",
          mxid: "$root-mxid",
          parentChannelId: "chan-thread"
        )
      )
      check created.found
      check created.rec.id == "thread-1"
      check created.rec.rootDiscordId == "root-dcid"
      check created.rec.rootMxid == "$root-mxid"
      check created.rec.parentChannelId == "chan-thread"

      let byRoot = rt.threadRuntime.getThreadByRootMXID("$root-mxid")
      check byRoot.found
      check byRoot.rec.id == "thread-1"

      var rec = created.rec
      rec.creationNoticeMxid = "$thread-created"
      rt.threads.upsert(rec)
      let byCreation = rt.threadRuntime.getThreadByRootOrCreationNoticeMXID("$thread-created")
      check byCreation.found
      check byCreation.rec.id == "thread-1"
    finally:
      db.close()
      cleanupDb(dbPath)

  test "loadThread returns parent when available and rejects create without root context":
    let opened = openTempDb("thread-runtime-load")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)

      var parent = newPortalRecord(PortalKey(channelId: "chan-parent", receiver: ""), 0)
      rt.portals.upsert(parent)

      let created = rt.threadRuntime.loadThread(
        default(ThreadRecord),
        false,
        "thread-2",
        ThreadRootMessage(
          discordId: "discord-root-2",
          mxid: "$root-2",
          parentChannelId: "chan-parent"
        )
      )
      check created.found
      check created.parentFound
      check created.parent.key.channelId == "chan-parent"

      let invalid = rt.threadRuntime.loadThread(
        default(ThreadRecord),
        false,
        "thread-invalid",
        ThreadRootMessage()
      )
      check not invalid.found
    finally:
      db.close()
      cleanupDb(dbPath)

  test "threadFound and join/backfill decisions follow expected gating":
    let opened = openTempDb("thread-runtime-flow")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)

      var parent = newPortalRecord(PortalKey(channelId: "chan-flow", receiver: ""), 0)
      rt.portals.upsert(parent)

      let found = rt.threadRuntime.threadFound(
        sourceDiscordId = "source-1",
        userAlreadyInPortal = false,
        rootMessage = ThreadRootMessage(
          discordId: "root-3",
          mxid: "$root-3",
          parentChannelId: "chan-flow"
        ),
        threadId = "thread-3",
        metadata = ThreadMetadata(
          memberIdsPreview: @["source-1"],
          messageCount: 2
        )
      )
      check found.found
      check found.shouldSendCreationNotice
      check found.markUserInPortal
      check found.shouldInitialBackfill

      let join = rt.threadRuntime.joinThread(
        "thread-3",
        userAlreadyInPortal = false,
        initialThreadLimit = 20,
        hasLastThreadMessage = false
      )
      check join.shouldJoin
      check join.markPortalJoined
      check join.doBackfill

      check not rt.threadRuntime.maybeInitialBackfill("thread-3", 20, false)

      discard rt.threadRuntime.threadFound(
        sourceDiscordId = "source-2",
        userAlreadyInPortal = false,
        rootMessage = ThreadRootMessage(
          discordId: "root-4",
          mxid: "$root-4",
          parentChannelId: "chan-flow"
        ),
        threadId = "thread-4",
        metadata = ThreadMetadata(
          memberIdsPreview: @["source-2"],
          messageCount: 0
        )
      )
      check rt.threadRuntime.isInitialBackfillAttempted("thread-4")
      check not rt.threadRuntime.maybeInitialBackfill("thread-4", 20, false)
    finally:
      db.close()
      cleanupDb(dbPath)

  test "referer option format is stable":
    check refererOpt("guild-x", "channel-y", "thread-z") == "guild-x/channel-y/thread-z"
