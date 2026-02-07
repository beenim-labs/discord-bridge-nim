## Core command utility helpers adapted from commands.go.

import std/[base64, strutils]

const discordTokenEpoch* = 1293840000

proc decodeRawUrlBase64(value: string): tuple[ok: bool, decoded: string, err: string] =
  var normalized = value.replace('-', '+').replace('_', '/')
  let rem = normalized.len mod 4
  if rem != 0:
    normalized.add(repeat('=', 4 - rem))
  try:
    (true, decode(normalized), "")
  except ValueError as e:
    (false, "", e.msg)

proc decodeToken*(token: string): tuple[ok: bool, userId: int64, err: string] =
  let parts = token.split('.')
  if parts.len != 3:
    return (false, 0'i64, "invalid number of parts in token")

  let userPart = decodeRawUrlBase64(parts[0])
  if not userPart.ok:
    return (false, 0'i64, "invalid base64 in user ID part: " & userPart.err)

  let randomPart = decodeRawUrlBase64(parts[1])
  if not randomPart.ok:
    return (false, 0'i64, "invalid base64 in random part: " & randomPart.err)

  let checksumPart = decodeRawUrlBase64(parts[2])
  if not checksumPart.ok:
    return (false, 0'i64, "invalid base64 in checksum part: " & checksumPart.err)

  try:
    let parsed = parseBiggestInt(userPart.decoded)
    (true, int64(parsed), "")
  except ValueError as e:
    (false, 0'i64, "invalid number in decoded user ID part: " & e.msg)

proc isNumber*(str: string): bool =
  for chr in str:
    if chr < '0' or chr > '9':
      return false
  true
