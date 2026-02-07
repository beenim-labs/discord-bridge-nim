## User cache manager with DB-backed lazy loading.

import std/[tables, locks]
import database/[database, entities, store]

type
  UserManager* = ref object
    db*: BridgeDb
    lock: Lock
    byMxid: Table[string, UserRecord]
    byDiscord: Table[string, string]

proc newUserManager*(db: BridgeDb): UserManager =
  new(result)
  result.db = db
  initLock(result.lock)
  result.byMxid = initTable[string, UserRecord]()
  result.byDiscord = initTable[string, string]()

proc remember(mgr: UserManager, rec: UserRecord) =
  mgr.byMxid[rec.mxid] = rec
  if rec.discordId.len > 0:
    mgr.byDiscord[rec.discordId] = rec.mxid

proc cacheCount*(mgr: UserManager): int =
  withLock mgr.lock:
    result = mgr.byMxid.len

proc getByMXID*(mgr: UserManager, mxid: string, createIfMissing = true): tuple[found: bool, rec: UserRecord] =
  withLock mgr.lock:
    if mgr.byMxid.hasKey(mxid):
      return (true, mgr.byMxid[mxid])

  let fromDb = mgr.db.getUserByMXID(mxid)
  if fromDb.found:
    withLock mgr.lock:
      mgr.remember(fromDb.rec)
    return (true, fromDb.rec)

  if not createIfMissing:
    return (false, default(UserRecord))

  let created = newUserRecord(mxid)
  mgr.db.insertUser(created)
  withLock mgr.lock:
    mgr.remember(created)
  (true, created)

proc getByDiscordID*(mgr: UserManager, discordId: string): tuple[found: bool, rec: UserRecord] =
  withLock mgr.lock:
    if mgr.byDiscord.hasKey(discordId):
      let mxid = mgr.byDiscord[discordId]
      if mgr.byMxid.hasKey(mxid):
        return (true, mgr.byMxid[mxid])

  let fromDb = mgr.db.getUserByDiscordID(discordId)
  if not fromDb.found:
    return (false, default(UserRecord))
  withLock mgr.lock:
    mgr.remember(fromDb.rec)
  (true, fromDb.rec)

proc upsert*(mgr: UserManager, rec: UserRecord) =
  let existing = mgr.db.getUserByMXID(rec.mxid)
  if existing.found:
    mgr.db.updateUser(rec)
  else:
    mgr.db.insertUser(rec)
  withLock mgr.lock:
    mgr.remember(rec)
