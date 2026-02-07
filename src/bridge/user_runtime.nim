## Runtime startup orchestration for users with Discord tokens.

import std/[asyncdispatch, json, locks, strutils, tables, times]
import database/[database, entities, store]
import bridge/managers/users

type
  UserStartupState* = object
    mxid*: string
    attemptCount*: int
    connected*: bool
    status*: string
    lastError*: string
    nextRetryAtMs*: int64
    lastUpdateMs*: int64

  UserStartupCoordinator* = ref object
    db*: BridgeDb
    users*: UserManager
    lock: Lock
    canceled*: bool
    running*: bool
    maxRetries*: int
    states: Table[string, UserStartupState]
    activeWorkers: int

proc nowMs(): int64 =
  getTime().toUnix().int64 * 1000

proc retryDelayMs*(retryCount: int): int64 =
  int64((2 shl retryCount) * 1000)

proc newUserStartupCoordinator*(db: BridgeDb, users: UserManager): UserStartupCoordinator =
  new(result)
  result.db = db
  result.users = users
  result.canceled = false
  result.running = false
  result.maxRetries = 6
  result.states = initTable[string, UserStartupState]()
  result.activeWorkers = 0
  initLock(result.lock)

proc parseRetryPrefix(token: string): tuple[hasRetry: bool, retriesBeforeSuccess: int] =
  if not token.startsWith("retry:"):
    return (false, 0)

  let first = token.find(':')
  let second = token.find(':', first + 1)
  if first < 0 or second < 0:
    return (false, 0)
  let retryPart = token[first + 1 ..< second]
  try:
    let n = parseInt(retryPart)
    if n >= 0:
      return (true, n)
  except CatchableError:
    discard
  (false, 0)

proc shouldConnect(token: string, retryCount: int): tuple[ok: bool, err: string] =
  if token.len == 0:
    return (false, "not logged in")
  if token.startsWith("fail:"):
    return (false, token[5 .. ^1])

  let retry = parseRetryPrefix(token)
  if retry.hasRetry and retryCount < retry.retriesBeforeSuccess:
    return (false, "transient startup failure")
  (true, "")

proc markWorkerDone(coord: UserStartupCoordinator) =
  withLock coord.lock:
    if coord.activeWorkers > 0:
      dec coord.activeWorkers
    if coord.activeWorkers == 0:
      coord.running = false

proc setState(coord: UserStartupCoordinator, state: UserStartupState) =
  withLock coord.lock:
    coord.states[state.mxid] = state

proc isCanceled(coord: UserStartupCoordinator): bool =
  withLock coord.lock:
    result = coord.canceled

proc startupTryConnect(coord: UserStartupCoordinator, mxid: string, retryCount: int): Future[void] {.async.} =
  if coord.isCanceled():
    var canceledState = UserStartupState(
      mxid: mxid,
      attemptCount: retryCount,
      connected: false,
      status: "canceled",
      lastError: "startup canceled",
      nextRetryAtMs: 0,
      lastUpdateMs: nowMs()
    )
    coord.setState(canceledState)
    coord.markWorkerDone()
    return

  let fetched = coord.users.getByMXID(mxid, createIfMissing = false)
  if not fetched.found:
    var missing = UserStartupState(
      mxid: mxid,
      attemptCount: retryCount,
      connected: false,
      status: "failed",
      lastError: "user not found",
      nextRetryAtMs: 0,
      lastUpdateMs: nowMs()
    )
    coord.setState(missing)
    coord.markWorkerDone()
    return

  var user = fetched.rec
  var state = UserStartupState(
    mxid: mxid,
    attemptCount: retryCount + 1,
    connected: false,
    status: "connecting",
    lastError: "",
    nextRetryAtMs: 0,
    lastUpdateMs: nowMs()
  )
  coord.setState(state)

  let attempt = shouldConnect(user.discordToken, retryCount)
  if attempt.ok:
    state.connected = true
    state.status = "connected"
    state.lastError = ""
    state.lastUpdateMs = nowMs()
    coord.setState(state)
    coord.markWorkerDone()
    return

  if retryCount >= coord.maxRetries:
    state.status = "failed"
    state.lastError = attempt.err
    state.nextRetryAtMs = 0
    state.lastUpdateMs = nowMs()
    coord.setState(state)
    coord.markWorkerDone()
    return

  let delay = retryDelayMs(retryCount)
  state.status = "retrying"
  state.lastError = attempt.err
  state.nextRetryAtMs = nowMs() + delay
  state.lastUpdateMs = nowMs()
  coord.setState(state)

  await sleepAsync(int(delay))
  await coord.startupTryConnect(mxid, retryCount + 1)

proc startUsers*(coord: UserStartupCoordinator) =
  if coord == nil:
    return

  withLock coord.lock:
    if coord.running:
      return
    coord.running = true
    coord.canceled = false
    coord.states.clear()
    coord.activeWorkers = 0

  let usersWithToken = coord.db.getAllUsersWithToken()
  if usersWithToken.len == 0:
    withLock coord.lock:
      coord.running = false
    return

  for rec in usersWithToken:
    discard coord.users.getByMXID(rec.mxid, createIfMissing = true)
    coord.users.upsert(rec)

    let initial = UserStartupState(
      mxid: rec.mxid,
      attemptCount: 0,
      connected: false,
      status: "pending",
      lastError: "",
      nextRetryAtMs: 0,
      lastUpdateMs: nowMs()
    )
    coord.setState(initial)
    withLock coord.lock:
      inc coord.activeWorkers
    asyncCheck coord.startupTryConnect(rec.mxid, 0)

proc stop*(coord: UserStartupCoordinator) =
  if coord == nil:
    return

  withLock coord.lock:
    coord.canceled = true
    coord.running = false
    for mxid, state in mpairs(coord.states):
      if not state.connected:
        state.status = "canceled"
        state.lastError = "startup canceled"
        state.nextRetryAtMs = 0
        state.lastUpdateMs = nowMs()
        coord.states[mxid] = state

proc health*(coord: UserStartupCoordinator): JsonNode =
  if coord == nil:
    return %*{
      "runtime_startup_running": false,
      "runtime_startup_users_total": 0,
      "runtime_startup_users_connected": 0,
      "runtime_startup_users_failed": 0,
      "runtime_startup_users_pending": 0
    }

  var total = 0
  var connected = 0
  var failed = 0
  var pending = 0
  var running = false
  withLock coord.lock:
    total = coord.states.len
    running = coord.running
    for _, state in coord.states:
      if state.connected or state.status == "connected":
        inc connected
      elif state.status == "failed":
        inc failed
      else:
        inc pending

  %*{
    "runtime_startup_running": running,
    "runtime_startup_users_total": total,
    "runtime_startup_users_connected": connected,
    "runtime_startup_users_failed": failed,
    "runtime_startup_users_pending": pending
  }
