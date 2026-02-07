## Guild cache manager with DB-backed lazy loading.

import std/[tables, locks]
import database/[database, entities, store]

type
  GuildManager* = ref object
    db*: BridgeDb
    lock: Lock
    byId: Table[string, GuildRecord]
    byMxid: Table[string, string]

proc newGuildManager*(db: BridgeDb): GuildManager =
  new(result)
  result.db = db
  initLock(result.lock)
  result.byId = initTable[string, GuildRecord]()
  result.byMxid = initTable[string, string]()

proc remember(mgr: GuildManager, rec: GuildRecord) =
  mgr.byId[rec.id] = rec
  if rec.mxid.len > 0:
    mgr.byMxid[rec.mxid] = rec.id

proc cacheCount*(mgr: GuildManager): int =
  withLock mgr.lock:
    result = mgr.byId.len

proc getByID*(mgr: GuildManager, id: string, createIfMissing = false): tuple[found: bool, rec: GuildRecord] =
  withLock mgr.lock:
    if mgr.byId.hasKey(id):
      return (true, mgr.byId[id])

  let fromDb = mgr.db.getGuildByID(id)
  if fromDb.found:
    withLock mgr.lock:
      mgr.remember(fromDb.rec)
    return (true, fromDb.rec)

  if not createIfMissing:
    return (false, default(GuildRecord))

  let created = newGuildRecord(id)
  mgr.db.insertGuild(created)
  withLock mgr.lock:
    mgr.remember(created)
  (true, created)

proc getByMXID*(mgr: GuildManager, mxid: string): tuple[found: bool, rec: GuildRecord] =
  withLock mgr.lock:
    if mgr.byMxid.hasKey(mxid):
      let id = mgr.byMxid[mxid]
      if mgr.byId.hasKey(id):
        return (true, mgr.byId[id])

  let fromDb = mgr.db.getGuildByMXID(mxid)
  if not fromDb.found:
    return (false, default(GuildRecord))
  withLock mgr.lock:
    mgr.remember(fromDb.rec)
  (true, fromDb.rec)

proc upsert*(mgr: GuildManager, rec: GuildRecord) =
  let existing = mgr.db.getGuildByID(rec.id)
  if existing.found:
    mgr.db.updateGuild(rec)
  else:
    mgr.db.insertGuild(rec)
  withLock mgr.lock:
    mgr.remember(rec)

proc getAll*(mgr: GuildManager): seq[GuildRecord] =
  ## Returns all cached guild records.
  result = @[]
  withLock mgr.lock:
    for _, rec in mgr.byId:
      result.add(rec)

proc delete*(mgr: GuildManager, id: string) =
  mgr.db.deleteGuild(id)
  withLock mgr.lock:
    if mgr.byId.hasKey(id):
      let mxid = mgr.byId[id].mxid
      if mxid.len > 0 and mgr.byMxid.hasKey(mxid):
        mgr.byMxid.del(mxid)
      mgr.byId.del(id)
