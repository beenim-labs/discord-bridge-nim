## Puppet cache manager with DB-backed lazy loading.

import std/[tables, locks]
import database/[database, entities, store]

type
  PuppetManager* = ref object
    db*: BridgeDb
    lock: Lock
    byId: Table[string, PuppetRecord]
    byCustomMxid: Table[string, string]

proc newPuppetManager*(db: BridgeDb): PuppetManager =
  new(result)
  result.db = db
  initLock(result.lock)
  result.byId = initTable[string, PuppetRecord]()
  result.byCustomMxid = initTable[string, string]()

proc remember(mgr: PuppetManager, rec: PuppetRecord) =
  if mgr.byId.hasKey(rec.id):
    let prev = mgr.byId[rec.id]
    if prev.customMxid.len > 0 and prev.customMxid != rec.customMxid:
      if mgr.byCustomMxid.hasKey(prev.customMxid) and mgr.byCustomMxid[prev.customMxid] == rec.id:
        mgr.byCustomMxid.del(prev.customMxid)
  mgr.byId[rec.id] = rec
  if rec.customMxid.len > 0:
    mgr.byCustomMxid[rec.customMxid] = rec.id

proc cacheCount*(mgr: PuppetManager): int =
  withLock mgr.lock:
    result = mgr.byId.len

proc getByID*(mgr: PuppetManager, id: string, createIfMissing = false): tuple[found: bool, rec: PuppetRecord] =
  withLock mgr.lock:
    if mgr.byId.hasKey(id):
      return (true, mgr.byId[id])

  let fromDb = mgr.db.getPuppetByID(id)
  if fromDb.found:
    withLock mgr.lock:
      mgr.remember(fromDb.rec)
    return (true, fromDb.rec)

  if not createIfMissing:
    return (false, default(PuppetRecord))

  let created = newPuppetRecord(id)
  mgr.db.insertPuppet(created)
  withLock mgr.lock:
    mgr.remember(created)
  (true, created)

proc getByCustomMXID*(mgr: PuppetManager, mxid: string): tuple[found: bool, rec: PuppetRecord] =
  withLock mgr.lock:
    if mgr.byCustomMxid.hasKey(mxid):
      let id = mgr.byCustomMxid[mxid]
      if mgr.byId.hasKey(id):
        return (true, mgr.byId[id])

  let fromDb = mgr.db.getPuppetByCustomMXID(mxid)
  if not fromDb.found:
    return (false, default(PuppetRecord))
  withLock mgr.lock:
    mgr.remember(fromDb.rec)
  (true, fromDb.rec)

proc upsert*(mgr: PuppetManager, rec: PuppetRecord) =
  let existing = mgr.db.getPuppetByID(rec.id)
  if existing.found:
    mgr.db.updatePuppet(rec)
  else:
    mgr.db.insertPuppet(rec)
  withLock mgr.lock:
    mgr.remember(rec)
