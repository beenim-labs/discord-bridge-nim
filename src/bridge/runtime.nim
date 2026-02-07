## Bridge runtime object graph and cache managers.

import std/[json, times, locks]
import config/config
import database/database
import bridge/managers/[users, portals, guilds, threads, puppets]
import bridge/user_runtime
import bridge/thread_runtime

export users, portals, guilds, threads, puppets, user_runtime, thread_runtime

type
  DiscordBridgeRuntime* = ref object
    cfg*: Config
    db*: BridgeDb

    users*: UserManager
    portals*: PortalManager
    guilds*: GuildManager
    threads*: ThreadManager
    puppets*: PuppetManager
    userStartup*: UserStartupCoordinator
    threadRuntime*: ThreadRuntime

    started*: bool
    startedAtMs*: int64
    lock: Lock

proc newDiscordBridgeRuntime*(cfg: Config, db: BridgeDb): DiscordBridgeRuntime =
  new(result)
  result.cfg = cfg
  result.db = db
  result.users = newUserManager(db)
  result.portals = newPortalManager(db)
  result.guilds = newGuildManager(db)
  result.threads = newThreadManager(db)
  result.puppets = newPuppetManager(db)
  result.userStartup = newUserStartupCoordinator(db, result.users)
  result.threadRuntime = newThreadRuntime(result.threads, result.portals)
  result.started = false
  result.startedAtMs = 0
  initLock(result.lock)

proc start*(rt: DiscordBridgeRuntime) =
  if rt == nil:
    return
  withLock rt.lock:
    rt.started = true
    rt.startedAtMs = getTime().toUnix().int64 * 1000
  if rt.userStartup != nil:
    rt.userStartup.startUsers()

proc stop*(rt: DiscordBridgeRuntime) =
  if rt == nil:
    return
  if rt.userStartup != nil:
    rt.userStartup.stop()
  withLock rt.lock:
    rt.started = false

proc health*(rt: DiscordBridgeRuntime): JsonNode =
  if rt == nil:
    return %*{"runtime_started": false}

  var started = false
  var startedAt = 0'i64
  withLock rt.lock:
    started = rt.started
    startedAt = rt.startedAtMs

  let startup = if rt.userStartup != nil: rt.userStartup.health() else: %*{
    "runtime_startup_running": false,
    "runtime_startup_users_total": 0,
    "runtime_startup_users_connected": 0,
    "runtime_startup_users_failed": 0,
    "runtime_startup_users_pending": 0
  }

  %*{
    "runtime_started": started,
    "runtime_started_at_ms": startedAt,
    "runtime_users_cached": rt.users.cacheCount(),
    "runtime_portals_cached": rt.portals.cacheCount(),
    "runtime_guilds_cached": rt.guilds.cacheCount(),
    "runtime_threads_cached": rt.threads.cacheCount(),
    "runtime_puppets_cached": rt.puppets.cacheCount(),
    "runtime_startup_running": startup["runtime_startup_running"],
    "runtime_startup_users_total": startup["runtime_startup_users_total"],
    "runtime_startup_users_connected": startup["runtime_startup_users_connected"],
    "runtime_startup_users_failed": startup["runtime_startup_users_failed"],
    "runtime_startup_users_pending": startup["runtime_startup_users_pending"]
  }
