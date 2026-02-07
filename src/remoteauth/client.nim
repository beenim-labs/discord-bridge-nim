## Discord remote auth (QR login) packet/state handling.
## This module implements protocol packet parsing and deterministic state updates.

import std/[json, base64, openssl]
import remoteauth/user

type
  DecryptPayloadFn* = proc(payload: string): tuple[ok: bool, plaintext: string, err: string] {.closure, gcsafe.}

  ServerPacketKind* = enum
    spkUnknown
    spkHello
    spkNonceProof
    spkPendingRemoteInit
    spkPendingTicket
    spkPendingLogin
    spkCancel
    spkHeartbeatAck

  ServerPacket* = object
    kind*: ServerPacketKind
    timeoutMs*: int
    heartbeatIntervalMs*: int
    encryptedNonce*: string
    fingerprint*: string
    encryptedUserPayload*: string
    ticket*: string

  RemoteAuthActionKind* = enum
    raaNoop
    raaSendPacket
    raaQrCode
    raaUserUpdated
    raaTicketReceived
    raaCancel
    raaHeartbeatAck

  RemoteAuthAction* = object
    kind*: RemoteAuthActionKind
    outboundJson*: string
    qrUrl*: string
    user*: RemoteAuthUser
    ticket*: string

  RemoteAuthClient* = ref object
    url*: string
    encodedPublicKey*: string

    heartbeatIntervalMs*: int
    timeoutMs*: int
    heartbeatsInFlight*: int

    lastQrUrl*: string
    user*: RemoteAuthUser
    ticket*: string
    closed*: bool
    lastError*: string

    decryptor*: DecryptPayloadFn

const
  DefaultRemoteAuthUrl* = "wss://remote-auth-gateway.discord.gg/?v=2"

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc encodeRawUrlBase64(data: seq[byte]): string =
  result = encode(bytesToString(data), safe = true)
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

proc sha256Digest(data: string): seq[byte] =
  let ctx = EVP_MD_CTX_create()
  if ctx.isNil:
    raise newException(IOError, "failed to allocate EVP context")
  defer:
    EVP_MD_CTX_destroy(ctx)

  if EVP_DigestInit_ex(ctx, EVP_sha256()) != 1:
    raise newException(IOError, "EVP_DigestInit_ex failed")
  if data.len > 0 and EVP_DigestUpdate(ctx, unsafeAddr data[0], cuint(data.len)) != 1:
    raise newException(IOError, "EVP_DigestUpdate failed")

  var outBuf: array[64, byte] = default(array[64, byte])
  var outLen: cuint = 0
  if EVP_DigestFinal_ex(ctx, addr outBuf[0], addr outLen) != 1:
    raise newException(IOError, "EVP_DigestFinal_ex failed")

  result = @[]
  for i in 0 ..< int(outLen):
    result.add(outBuf[i])

proc nonceProofFromPlaintext*(plaintext: string): string =
  let digest = sha256Digest(plaintext)
  encodeRawUrlBase64(digest)

proc heartbeatPacketJson*(): string =
  $(%*{"op": "heartbeat"})

proc initPacketJson*(encodedPublicKey: string): string =
  $(%*{
    "op": "init",
    "encoded_public_key": encodedPublicKey
  })

proc nonceProofPacketJson*(proof: string): string =
  $(%*{
    "op": "nonce_proof",
    "proof": proof
  })

proc parseServerPacket*(payload: string): tuple[ok: bool, pkt: ServerPacket, err: string] {.gcsafe.} =
  var body: JsonNode = newJObject()
  try:
    body = parseJson(payload)
  except CatchableError as e:
    return (false, ServerPacket(), "invalid JSON: " & e.msg)

  if body.kind != JObject:
    return (false, ServerPacket(), "packet must be a JSON object")
  if not body.hasKey("op") or body["op"].kind != JString:
    return (false, ServerPacket(), "packet missing string op")

  let op = body["op"].getStr()
  case op
  of "hello":
    (
      true,
      ServerPacket(
        kind: spkHello,
        timeoutMs: if body.hasKey("timeout_ms"): body["timeout_ms"].getInt() else: 0,
        heartbeatIntervalMs: if body.hasKey("heartbeat_interval"): body["heartbeat_interval"].getInt() else: 0
      ),
      ""
    )
  of "nonce_proof":
    (
      true,
      ServerPacket(
        kind: spkNonceProof,
        encryptedNonce: if body.hasKey("encrypted_nonce"): body["encrypted_nonce"].getStr() else: ""
      ),
      ""
    )
  of "pending_remote_init":
    (
      true,
      ServerPacket(
        kind: spkPendingRemoteInit,
        fingerprint: if body.hasKey("fingerprint"): body["fingerprint"].getStr() else: ""
      ),
      ""
    )
  of "pending_ticket":
    (
      true,
      ServerPacket(
        kind: spkPendingTicket,
        encryptedUserPayload: if body.hasKey("encrypted_user_payload"): body["encrypted_user_payload"].getStr() else: ""
      ),
      ""
    )
  of "pending_login":
    (
      true,
      ServerPacket(
        kind: spkPendingLogin,
        ticket: if body.hasKey("ticket"): body["ticket"].getStr() else: ""
      ),
      ""
    )
  of "cancel":
    (true, ServerPacket(kind: spkCancel), "")
  of "heartbeat_ack":
    (true, ServerPacket(kind: spkHeartbeatAck), "")
  else:
    (false, ServerPacket(), "unknown op " & op)

proc buildQrUrl*(fingerprint: string): string =
  "https://discordapp.com/ra/" & fingerprint

proc newRemoteAuthClient*(): RemoteAuthClient =
  RemoteAuthClient(
    url: DefaultRemoteAuthUrl,
    encodedPublicKey: "",
    heartbeatIntervalMs: 0,
    timeoutMs: 0,
    heartbeatsInFlight: 0,
    lastQrUrl: "",
    user: RemoteAuthUser(),
    ticket: "",
    closed: false,
    lastError: "",
    decryptor: nil
  )

proc setEncodedPublicKey*(c: RemoteAuthClient, encodedPublicKey: string) =
  c.encodedPublicKey = encodedPublicKey

proc setDecryptor*(c: RemoteAuthClient, decryptor: DecryptPayloadFn) =
  c.decryptor = decryptor

proc markHeartbeatSent*(c: RemoteAuthClient): tuple[ok: bool, err: string] =
  inc c.heartbeatsInFlight
  if c.heartbeatsInFlight > 2:
    return (false, "server failed to acknowledge our heartbeats")
  (true, "")

proc nextHeartbeatPacket*(c: RemoteAuthClient): tuple[ok: bool, packetJson: string, err: string] =
  let marked = c.markHeartbeatSent()
  if not marked.ok:
    c.lastError = marked.err
    return (false, "", marked.err)
  (true, heartbeatPacketJson(), "")

proc processServerPacket*(c: RemoteAuthClient, payload: string): tuple[ok: bool, action: RemoteAuthAction, err: string] {.gcsafe.} =
  let parsed = parseServerPacket(payload)
  if not parsed.ok:
    c.lastError = parsed.err
    return (false, RemoteAuthAction(), parsed.err)

  case parsed.pkt.kind
  of spkHello:
    c.timeoutMs = parsed.pkt.timeoutMs
    c.heartbeatIntervalMs = parsed.pkt.heartbeatIntervalMs
    let packet = initPacketJson(c.encodedPublicKey)
    (
      true,
      RemoteAuthAction(kind: raaSendPacket, outboundJson: packet),
      ""
    )
  of spkNonceProof:
    if c.decryptor == nil:
      let err = "nonce_proof received but decryptor is not configured"
      c.lastError = err
      return (false, RemoteAuthAction(), err)
    let decrypted = c.decryptor(parsed.pkt.encryptedNonce)
    if not decrypted.ok:
      c.lastError = decrypted.err
      return (false, RemoteAuthAction(), decrypted.err)
    let proof = nonceProofFromPlaintext(decrypted.plaintext)
    (
      true,
      RemoteAuthAction(kind: raaSendPacket, outboundJson: nonceProofPacketJson(proof)),
      ""
    )
  of spkPendingRemoteInit:
    c.lastQrUrl = buildQrUrl(parsed.pkt.fingerprint)
    (
      true,
      RemoteAuthAction(kind: raaQrCode, qrUrl: c.lastQrUrl),
      ""
    )
  of spkPendingTicket:
    if c.decryptor == nil:
      let err = "pending_ticket received but decryptor is not configured"
      c.lastError = err
      return (false, RemoteAuthAction(), err)
    let decrypted = c.decryptor(parsed.pkt.encryptedUserPayload)
    if not decrypted.ok:
      c.lastError = decrypted.err
      return (false, RemoteAuthAction(), decrypted.err)
    let updated = c.user.updateFromPayload(decrypted.plaintext)
    if not updated.ok:
      c.lastError = updated.err
      return (false, RemoteAuthAction(), updated.err)
    (
      true,
      RemoteAuthAction(kind: raaUserUpdated, user: c.user),
      ""
    )
  of spkPendingLogin:
    c.ticket = parsed.pkt.ticket
    (
      true,
      RemoteAuthAction(kind: raaTicketReceived, ticket: parsed.pkt.ticket),
      ""
    )
  of spkCancel:
    c.closed = true
    (
      true,
      RemoteAuthAction(kind: raaCancel),
      ""
    )
  of spkHeartbeatAck:
    if c.heartbeatsInFlight > 0:
      dec c.heartbeatsInFlight
    (
      true,
      RemoteAuthAction(kind: raaHeartbeatAck),
      ""
    )
  else:
    let err = "unsupported packet kind"
    c.lastError = err
    (false, RemoteAuthAction(), err)
