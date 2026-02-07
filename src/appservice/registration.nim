## Appservice registration generation and parsing.

import std/[strformat, random, tables]
import common/simple_yaml
import config/config

type
  Registration* = object
    id*: string
    url*: string
    asToken*: string
    hsToken*: string
    senderLocalpart*: string

proc token(n = 64): string =
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  randomize()
  result = newStringOfCap(n)
  for _ in 0 ..< n:
    result.add chars[rand(chars.len - 1)]

proc senderLocalpartFromConfig(cfg: Config): string =
  if cfg.appservice.bot.username.len > 0:
    return cfg.appservice.bot.username
  cfg.appservice.id & "bot"

proc makeUserRegex(cfg: Config): string =
  "^@" & cfg.appservice.id & "_.*:" & cfg.homeserver.domain & "$"

proc makeAliasRegex(cfg: Config): string =
  "^#" & cfg.appservice.id & "_.*:" & cfg.homeserver.domain & "$"

proc buildRegistration*(cfg: Config): Registration =
  Registration(
    id: cfg.appservice.id,
    url: cfg.appservice.address,
    asToken: token(),
    hsToken: token(),
    senderLocalpart: senderLocalpartFromConfig(cfg)
  )

proc writeRegistration*(path: string, cfg: Config, reg: Registration) =
  let content = fmt"""
id: {reg.id}
url: {reg.url}
as_token: {reg.asToken}
hs_token: {reg.hsToken}
sender_localpart: {reg.senderLocalpart}
rate_limited: false
namespaces:
  users:
    - regex: {makeUserRegex(cfg)}
      exclusive: true
  aliases:
    - regex: {makeAliasRegex(cfg)}
      exclusive: true
  rooms: []
"""
  writeFile(path, content)

proc readRegistration*(path: string): Registration =
  let y = parseSimpleYamlFile(path)
  Registration(
    id: y.getOrDefault("id", ""),
    url: y.getOrDefault("url", ""),
    asToken: y.getOrDefault("as_token", ""),
    hsToken: y.getOrDefault("hs_token", ""),
    senderLocalpart: y.getOrDefault("sender_localpart", "")
  )
