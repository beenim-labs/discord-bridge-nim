## Portal cache manager with DB-backed lazy loading.

import std/[tables, locks]
import database/[database, entities, store]

type
  PortalManager* = ref object
    db*: BridgeDb
    lock: Lock
    byKey: Table[string, PortalRecord]
    byMxid: Table[string, string]

proc keyId(key: PortalKey): string =
  key.channelId & "\x1f" & key.receiver

proc newPortalManager*(db: BridgeDb): PortalManager =
  new(result)
  result.db = db
  initLock(result.lock)
  result.byKey = initTable[string, PortalRecord]()
  result.byMxid = initTable[string, string]()

proc remember(mgr: PortalManager, rec: PortalRecord) =
  let id = keyId(rec.key)
  mgr.byKey[id] = rec
  if rec.mxid.len > 0:
    mgr.byMxid[rec.mxid] = id

proc cacheCount*(mgr: PortalManager): int =
  withLock mgr.lock:
    result = mgr.byKey.len

proc getByID*(mgr: PortalManager, key: PortalKey, createIfMissing = false, portalType = 0): tuple[found: bool, rec: PortalRecord] =
  let id = keyId(key)
  withLock mgr.lock:
    if mgr.byKey.hasKey(id):
      return (true, mgr.byKey[id])

  let fromDb = mgr.db.getPortalByID(key)
  if fromDb.found:
    withLock mgr.lock:
      mgr.remember(fromDb.rec)
    return (true, fromDb.rec)

  if not createIfMissing:
    return (false, default(PortalRecord))

  let created = newPortalRecord(key, portalType)
  mgr.db.insertPortal(created)
  withLock mgr.lock:
    mgr.remember(created)
  (true, created)

proc getByMXID*(mgr: PortalManager, mxid: string): tuple[found: bool, rec: PortalRecord] =
  withLock mgr.lock:
    if mgr.byMxid.hasKey(mxid):
      let id = mgr.byMxid[mxid]
      if mgr.byKey.hasKey(id):
        return (true, mgr.byKey[id])

  let fromDb = mgr.db.getPortalByMXID(mxid)
  if not fromDb.found:
    return (false, default(PortalRecord))
  withLock mgr.lock:
    mgr.remember(fromDb.rec)
  (true, fromDb.rec)

proc upsert*(mgr: PortalManager, rec: PortalRecord) =
  let existing = mgr.db.getPortalByID(rec.key)
  if existing.found:
    mgr.db.updatePortal(rec)
  else:
    mgr.db.insertPortal(rec)
  withLock mgr.lock:
    mgr.remember(rec)

proc findPrivateChatWith*(mgr: PortalManager, selfId: string, otherId: string): tuple[found: bool, rec: PortalRecord] =
  ## Find a DM portal between two users.
  let results = mgr.db.findPrivateChatsOf(selfId, dmType = 1)
  for p in results:
    if p.otherUserId == otherId:
      return (true, p)
  (false, default(PortalRecord))

proc delete*(mgr: PortalManager, key: PortalKey) =
  mgr.db.deletePortal(key)
  let id = keyId(key)
  withLock mgr.lock:
    if mgr.byKey.hasKey(id):
      let mxid = mgr.byKey[id].mxid
      if mxid.len > 0 and mgr.byMxid.hasKey(mxid):
        mgr.byMxid.del(mxid)
      mgr.byKey.del(id)
