## Thread cache manager with DB-backed lazy loading.

import std/[tables, locks]
import database/[database, entities, store]

type
  ThreadManager* = ref object
    db*: BridgeDb
    lock: Lock
    byId: Table[string, ThreadRecord]
    byRootMxid: Table[string, string]
    byCreationNoticeMxid: Table[string, string]

proc newThreadManager*(db: BridgeDb): ThreadManager =
  new(result)
  result.db = db
  initLock(result.lock)
  result.byId = initTable[string, ThreadRecord]()
  result.byRootMxid = initTable[string, string]()
  result.byCreationNoticeMxid = initTable[string, string]()

proc remember(mgr: ThreadManager, rec: ThreadRecord) =
  mgr.byId[rec.id] = rec
  if rec.rootMxid.len > 0:
    mgr.byRootMxid[rec.rootMxid] = rec.id
  if rec.creationNoticeMxid.len > 0:
    mgr.byCreationNoticeMxid[rec.creationNoticeMxid] = rec.id

proc cacheCount*(mgr: ThreadManager): int =
  withLock mgr.lock:
    result = mgr.byId.len

proc getByID*(mgr: ThreadManager, id: string, createIfMissing = false): tuple[found: bool, rec: ThreadRecord] =
  withLock mgr.lock:
    if mgr.byId.hasKey(id):
      return (true, mgr.byId[id])

  let fromDb = mgr.db.getThreadByDiscordID(id)
  if fromDb.found:
    withLock mgr.lock:
      mgr.remember(fromDb.rec)
    return (true, fromDb.rec)

  if not createIfMissing:
    return (false, default(ThreadRecord))

  let created = newThreadRecord(id)
  mgr.db.insertThread(created)
  withLock mgr.lock:
    mgr.remember(created)
  (true, created)

proc getByRootMXID*(mgr: ThreadManager, mxid: string): tuple[found: bool, rec: ThreadRecord] =
  withLock mgr.lock:
    if mgr.byRootMxid.hasKey(mxid):
      let id = mgr.byRootMxid[mxid]
      if mgr.byId.hasKey(id):
        return (true, mgr.byId[id])

  let fromDb = mgr.db.getThreadByMatrixRootMsg(mxid)
  if not fromDb.found:
    return (false, default(ThreadRecord))
  withLock mgr.lock:
    mgr.remember(fromDb.rec)
  (true, fromDb.rec)

proc getByRootOrCreationNoticeMXID*(mgr: ThreadManager, mxid: string): tuple[found: bool, rec: ThreadRecord] =
  withLock mgr.lock:
    if mgr.byRootMxid.hasKey(mxid):
      let id = mgr.byRootMxid[mxid]
      if mgr.byId.hasKey(id):
        return (true, mgr.byId[id])
    if mgr.byCreationNoticeMxid.hasKey(mxid):
      let id = mgr.byCreationNoticeMxid[mxid]
      if mgr.byId.hasKey(id):
        return (true, mgr.byId[id])

  let fromDb = mgr.db.getThreadByMatrixRootOrCreationNoticeMsg(mxid)
  if not fromDb.found:
    return (false, default(ThreadRecord))
  withLock mgr.lock:
    mgr.remember(fromDb.rec)
  (true, fromDb.rec)

proc upsert*(mgr: ThreadManager, rec: ThreadRecord) =
  let existing = mgr.db.getThreadByDiscordID(rec.id)
  if existing.found:
    mgr.db.updateThread(rec)
  else:
    mgr.db.insertThread(rec)
  withLock mgr.lock:
    mgr.remember(rec)

proc delete*(mgr: ThreadManager, rec: ThreadRecord) =
  mgr.db.deleteThread(rec)
  withLock mgr.lock:
    if mgr.byId.hasKey(rec.id):
      let cached = mgr.byId[rec.id]
      if cached.rootMxid.len > 0 and mgr.byRootMxid.hasKey(cached.rootMxid):
        mgr.byRootMxid.del(cached.rootMxid)
      if cached.creationNoticeMxid.len > 0 and mgr.byCreationNoticeMxid.hasKey(cached.creationNoticeMxid):
        mgr.byCreationNoticeMxid.del(cached.creationNoticeMxid)
      mgr.byId.del(rec.id)
