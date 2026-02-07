## Backfill utility parity helpers adapted from backfill.go.

import std/[algorithm, base64, strutils, openssl]

type
  BackfillMessageRef* = object
    id*: string

  MessageSlice* = seq[BackfillMessageRef]

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc sha256Bytes(data: string): array[32, byte] =
  result = default(array[32, byte])
  let ctx = EVP_MD_CTX_create()
  if ctx.isNil:
    return
  defer:
    EVP_MD_CTX_destroy(ctx)

  if EVP_DigestInit_ex(ctx, EVP_sha256()) != 1:
    return
  if data.len > 0 and EVP_DigestUpdate(ctx, unsafeAddr data[0], cuint(data.len)) != 1:
    return

  var digest: array[64, byte] = default(array[64, byte])
  var digestLen: cuint = 0
  if EVP_DigestFinal_ex(ctx, addr digest[0], addr digestLen) != 1:
    return
  for i in 0 ..< min(int(digestLen), 32):
    result[i] = digest[i]

proc rawUrlBase64(data: openArray[byte]): string =
  var encoded = encode(bytesToString(data))
  encoded = encoded.replace('+', '-').replace('/', '_')
  while encoded.len > 0 and encoded[^1] == '=':
    encoded.setLen(encoded.len - 1)
  encoded

proc deterministicEventID*(portalMxid, messageID, partName: string): string =
  let data = portalMxid & "/discord/" & messageID & "/" & partName
  let sum = sha256Bytes(data)
  "$" & rawUrlBase64(sum) & ":discord.com"

proc compareMessageIDs*(id1, id2: string): int =
  if id1 == id2:
    return 0
  if id1.len < id2.len:
    return -1
  if id2.len < id1.len:
    return 1
  if id1 < id2:
    return -1
  1

proc shouldBackfill*(latestBridgedIDStr, latestIDFromServerStr: string): bool =
  compareMessageIDs(latestBridgedIDStr, latestIDFromServerStr) == -1

proc len*(a: MessageSlice): int =
  system.len(a)

proc swap*(a: var MessageSlice, i, j: int) =
  let tmp = a[i]
  a[i] = a[j]
  a[j] = tmp

proc less*(a: MessageSlice, i, j: int): bool =
  compareMessageIDs(a[i].id, a[j].id) == -1

proc sortByDiscordID*(a: var MessageSlice) =
  a.sort(proc(x, y: BackfillMessageRef): int = compareMessageIDs(x.id, y.id))
