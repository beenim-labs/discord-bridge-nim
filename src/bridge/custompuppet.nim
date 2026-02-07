## Custom puppet parity helpers adapted from custompuppet.go.

import std/strutils
import bridge/runtime
import config/config

type
  DoublePuppetSetupResult* = object
    ok*: bool
    accessToken*: string
    err*: string

  DoublePuppetSetupProc* = proc(customMxid, accessToken: string, reloginOnFail: bool): DoublePuppetSetupResult {.closure, gcsafe.}

  CustomPuppetCoordinator* = ref object
    runtime*: DiscordBridgeRuntime
    setupProc*: DoublePuppetSetupProc

proc defaultSetup(customMxid, accessToken: string, reloginOnFail: bool): DoublePuppetSetupResult =
  if customMxid.len == 0:
    return DoublePuppetSetupResult(ok: false, accessToken: "", err: "custom mxid is required")
  if accessToken.startsWith("fail:"):
    return DoublePuppetSetupResult(ok: false, accessToken: "", err: accessToken[5 .. ^1])
  if accessToken.len == 0:
    if reloginOnFail:
      return DoublePuppetSetupResult(ok: true, accessToken: "shared-secret:" & customMxid, err: "")
    return DoublePuppetSetupResult(ok: false, accessToken: "", err: "access token is required")
  DoublePuppetSetupResult(ok: true, accessToken: accessToken, err: "")

proc newCustomPuppetCoordinator*(runtime: DiscordBridgeRuntime, setupProc: DoublePuppetSetupProc = nil): CustomPuppetCoordinator =
  new(result)
  result.runtime = runtime
  result.setupProc = if setupProc == nil: defaultSetup else: setupProc

proc clearCustomMXID*(coord: CustomPuppetCoordinator, puppetId: string) =
  if coord == nil or coord.runtime == nil or coord.runtime.puppets == nil:
    return
  let fetched = coord.runtime.puppets.getByID(puppetId, createIfMissing = false)
  if not fetched.found:
    return

  var rec = fetched.rec
  let save = rec.customMxid.len > 0 or rec.accessToken.len > 0
  rec.customMxid = ""
  rec.accessToken = ""
  if save:
    coord.runtime.puppets.upsert(rec)

proc startCustomMXID*(
    coord: CustomPuppetCoordinator,
    puppetId: string,
    reloginOnFail: bool
): tuple[ok: bool, err: string] =
  if coord == nil or coord.runtime == nil or coord.runtime.puppets == nil:
    return (false, "custom puppet coordinator is not configured")

  let fetched = coord.runtime.puppets.getByID(puppetId, createIfMissing = false)
  if not fetched.found:
    return (false, "puppet not found")

  var rec = fetched.rec
  let setup = coord.setupProc(rec.customMxid, rec.accessToken, reloginOnFail)
  if not setup.ok:
    coord.clearCustomMXID(puppetId)
    return (false, setup.err)

  if rec.accessToken != setup.accessToken:
    rec.accessToken = setup.accessToken
  coord.runtime.puppets.upsert(rec)

  if rec.customMxid.len > 0 and coord.runtime.users != nil:
    discard coord.runtime.users.getByMXID(rec.customMxid, createIfMissing = true)

  (true, "")

proc switchCustomMXID*(
    coord: CustomPuppetCoordinator,
    puppetId: string,
    accessToken: string,
    mxid: string
): tuple[ok: bool, err: string] =
  if coord == nil or coord.runtime == nil or coord.runtime.puppets == nil:
    return (false, "custom puppet coordinator is not configured")

  let fetched = coord.runtime.puppets.getByID(puppetId, createIfMissing = true)
  var rec = fetched.rec
  rec.customMxid = mxid
  rec.accessToken = accessToken
  coord.runtime.puppets.upsert(rec)

  let started = coord.startCustomMXID(puppetId, reloginOnFail = false)
  if not started.ok:
    return started
  (true, "")

proc tryAutomaticDoublePuppeting*(
    coord: CustomPuppetCoordinator,
    userMxid: string,
    userDiscordId: string
): tuple[attempted: bool, ok: bool, err: string] =
  if coord == nil or coord.runtime == nil:
    return (false, false, "custom puppet coordinator is not configured")
  if userMxid.len == 0 or userDiscordId.len == 0:
    return (false, false, "user identifiers are required")
  if not coord.runtime.cfg.canAutoDoublePuppet(userMxid):
    return (false, true, "")

  let fetched = coord.runtime.puppets.getByID(userDiscordId, createIfMissing = true)
  var rec = fetched.rec
  if rec.customMxid.len > 0:
    return (false, true, "")

  rec.customMxid = userMxid
  coord.runtime.puppets.upsert(rec)
  let started = coord.startCustomMXID(userDiscordId, reloginOnFail = true)
  if not started.ok:
    return (true, false, started.err)
  (true, true, "")
