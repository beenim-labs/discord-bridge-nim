## Compatibility helpers for `main.go` bridge-child methods.

import std/[strutils]
import config/config
import database/entities
import bridge/runtime

const
  PuppetIdPlaceholder = "{{.}}"
  ExampleConfigText* = staticRead("../../tests/fixtures/mautrix-discord.sample.yaml")

type
  DiscordBridgeCompat* = ref object
    cfg*: Config
    runtime*: DiscordBridgeRuntime

proc newDiscordBridgeCompat*(cfg: Config, runtime: DiscordBridgeRuntime): DiscordBridgeCompat =
  DiscordBridgeCompat(cfg: cfg, runtime: runtime)

proc getExampleConfig*(br: DiscordBridgeCompat): string =
  discard br
  ExampleConfigText

proc getConfigPtr*(br: DiscordBridgeCompat): ptr Config =
  if br == nil:
    return nil
  addr br.cfg

proc getIPortal*(br: DiscordBridgeCompat, mxid: string): tuple[found: bool, rec: PortalRecord] =
  if br == nil or br.runtime == nil:
    return (false, default(PortalRecord))
  br.runtime.portals.getByMXID(mxid)

proc getIUser*(br: DiscordBridgeCompat, mxid: string, create: bool): tuple[found: bool, rec: UserRecord] =
  if br == nil or br.runtime == nil:
    return (false, default(UserRecord))
  br.runtime.users.getByMXID(mxid, createIfMissing = create)

proc parseMatrixUserId(mxid: string): tuple[ok: bool, localpart: string, domain: string] =
  if mxid.len < 4 or mxid[0] != '@':
    return (false, "", "")
  let sep = mxid.find(':')
  if sep <= 1 or sep + 1 >= mxid.len:
    return (false, "", "")
  (true, mxid[1 ..< sep], mxid[sep + 1 .. ^1])

proc splitPuppetTemplate(tmplStr: string): tuple[ok: bool, prefix: string, suffix: string] =
  let idx = tmplStr.find(PuppetIdPlaceholder)
  if idx < 0:
    return (false, "", "")
  (
    true,
    tmplStr[0 ..< idx],
    tmplStr[idx + PuppetIdPlaceholder.len .. ^1]
  )

proc parsePuppetMXID*(br: DiscordBridgeCompat, mxid: string): tuple[discordId: string, ok: bool] =
  if br == nil:
    return ("", false)
  let parsed = parseMatrixUserId(mxid)
  if not parsed.ok:
    return ("", false)
  if br.cfg.homeserver.domain.len > 0 and parsed.domain != br.cfg.homeserver.domain:
    return ("", false)

  let tmpl = splitPuppetTemplate(br.cfg.bridge.usernameTemplate)
  if not tmpl.ok:
    return ("", false)
  if not parsed.localpart.startsWith(tmpl.prefix):
    return ("", false)
  if tmpl.suffix.len > 0 and not parsed.localpart.endsWith(tmpl.suffix):
    return ("", false)

  let idStart = tmpl.prefix.len
  let idEnd =
    if tmpl.suffix.len == 0:
      parsed.localpart.len
    else:
      parsed.localpart.len - tmpl.suffix.len
  if idEnd <= idStart:
    return ("", false)

  let discordId = parsed.localpart[idStart ..< idEnd]
  if discordId.len == 0:
    return ("", false)
  for ch in discordId:
    if ch < '0' or ch > '9':
      return ("", false)
  (discordId, true)

proc isGhost*(br: DiscordBridgeCompat, mxid: string): bool =
  br.parsePuppetMXID(mxid).ok

proc getIGhost*(br: DiscordBridgeCompat, mxid: string): tuple[found: bool, rec: PuppetRecord] =
  if br == nil or br.runtime == nil:
    return (false, default(PuppetRecord))
  let parsed = br.parsePuppetMXID(mxid)
  if not parsed.ok:
    return (false, default(PuppetRecord))
  br.runtime.puppets.getByID(parsed.discordId, createIfMissing = true)

proc createPrivatePortal*(
    br: DiscordBridgeCompat,
    roomId: string,
    userMxid: string,
    ghostMxid: string
): bool =
  discard br
  discard roomId
  discard userMxid
  discard ghostMxid
  ## Go baseline currently has TODO stub for this function.
  false
