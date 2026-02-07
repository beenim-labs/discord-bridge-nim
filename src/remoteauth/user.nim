## Remote auth user payload handling.

import std/[strutils]

type
  RemoteAuthUser* = object
    userId*: string
    discriminator*: string
    avatarHash*: string
    username*: string
    token*: string

proc parseUserPayload*(payload: string): tuple[ok: bool, user: RemoteAuthUser, err: string] =
  let parts = payload.split(':')
  if parts.len != 4:
    return (false, RemoteAuthUser(), "expected 4 parts but got " & $parts.len)
  (
    true,
    RemoteAuthUser(
      userId: parts[0],
      discriminator: parts[1],
      avatarHash: parts[2],
      username: parts[3],
      token: ""
    ),
    ""
  )

proc updateFromPayload*(user: var RemoteAuthUser, payload: string): tuple[ok: bool, err: string] =
  let parsed = parseUserPayload(payload)
  if not parsed.ok:
    return (false, parsed.err)
  user.userId = parsed.user.userId
  user.discriminator = parsed.user.discriminator
  user.avatarHash = parsed.user.avatarHash
  user.username = parsed.user.username
  (true, "")

proc update*(user: var RemoteAuthUser, payload: string): tuple[ok: bool, err: string] =
  user.updateFromPayload(payload)
