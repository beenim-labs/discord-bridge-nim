import std/[unittest, os, times, json]
import config/config
import database/[database, entities, store]
import bridge/runtime

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

suite "bridge runtime":
  test "managers cache and lazy load":
    let opened = openTempDb("runtime")
    let db = opened.db
    let dbPath = opened.path
    try:
      let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
      let rt = newDiscordBridgeRuntime(cfg, db)

      rt.start()
      let h1 = rt.health()
      check h1["runtime_started"].getBool()

      let u1 = rt.users.getByMXID("@runtime:test")
      check u1.found
      check u1.rec.mxid == "@runtime:test"

      var userRec = u1.rec
      userRec.discordId = "runtime-uid"
      rt.users.upsert(userRec)

      let byDiscord = rt.users.getByDiscordID("runtime-uid")
      check byDiscord.found
      check byDiscord.rec.mxid == "@runtime:test"

      var guild = newGuildRecord("guild-runtime")
      guild.name = "Runtime Guild"
      guild.plainName = "Runtime Guild"
      rt.guilds.upsert(guild)
      let g1 = rt.guilds.getByID("guild-runtime")
      check g1.found

      var parent = newPortalRecord(PortalKey(channelId: "chan-runtime", receiver: ""), 0)
      parent.guildId = "guild-runtime"
      parent.name = "runtime-chan"
      parent.plainName = "runtime-chan"
      parent.firstEventId = "$runtime"
      rt.portals.upsert(parent)
      let p1 = rt.portals.getByID(PortalKey(channelId: "chan-runtime", receiver: ""))
      check p1.found

      var thread = newThreadRecord("thread-runtime")
      thread.parentChannelId = "chan-runtime"
      thread.rootDiscordId = "discord-root"
      thread.rootMxid = "$root-mxid"
      thread.creationNoticeMxid = "$create-mxid"
      rt.threads.upsert(thread)
      let t1 = rt.threads.getByID("thread-runtime")
      check t1.found
      check rt.threads.getByRootMXID("$root-mxid").found
      check rt.threads.getByRootOrCreationNoticeMXID("$create-mxid").found

      var puppet = newPuppetRecord("puppet-runtime")
      puppet.customMxid = "@puppet-runtime:test"
      rt.puppets.upsert(puppet)
      check rt.puppets.getByID("puppet-runtime").found
      check rt.puppets.getByCustomMXID("@puppet-runtime:test").found

      let h2 = rt.health()
      check h2["runtime_users_cached"].getInt() >= 1
      check h2["runtime_portals_cached"].getInt() >= 1
      check h2["runtime_guilds_cached"].getInt() >= 1
      check h2["runtime_threads_cached"].getInt() >= 1
      check h2["runtime_puppets_cached"].getInt() >= 1
    finally:
      db.close()
      cleanupDb(dbPath)
