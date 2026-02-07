import std/[unittest, json]
import remoteauth/[client, user]

suite "remoteauth":
  test "parse and update user payload":
    let parsed = parseUserPayload("123:0001:hash:alice")
    check parsed.ok
    check parsed.user.userId == "123"
    check parsed.user.discriminator == "0001"
    check parsed.user.avatarHash == "hash"
    check parsed.user.username == "alice"

    var u = RemoteAuthUser()
    let updated = u.updateFromPayload("555:1234:av:bob")
    check updated.ok
    check u.userId == "555"
    check u.username == "bob"

    let updatedAlias = u.update("777:1111:av2:zoe")
    check updatedAlias.ok
    check u.userId == "777"
    check u.username == "zoe"

    let bad = parseUserPayload("x:y")
    check not bad.ok

  test "hello packet triggers init packet":
    let c = newRemoteAuthClient()
    c.setEncodedPublicKey("PUBKEY")
    let processed = c.processServerPacket("""{"op":"hello","timeout_ms":60000,"heartbeat_interval":41250}""")
    check processed.ok
    check c.timeoutMs == 60000
    check c.heartbeatIntervalMs == 41250
    check processed.action.kind == raaSendPacket

    let packetJson = parseJson(processed.action.outboundJson)
    check packetJson["op"].getStr() == "init"
    check packetJson["encoded_public_key"].getStr() == "PUBKEY"

  test "heartbeat counter and ack behavior":
    let c = newRemoteAuthClient()
    check c.nextHeartbeatPacket().ok
    check c.nextHeartbeatPacket().ok
    let third = c.nextHeartbeatPacket()
    check not third.ok
    check c.lastError.len > 0

    let acked = c.processServerPacket("""{"op":"heartbeat_ack"}""")
    check acked.ok
    check acked.action.kind == raaHeartbeatAck
    check c.heartbeatsInFlight == 2

  test "nonce proof packet uses decrypted payload hash":
    let c = newRemoteAuthClient()
    c.setDecryptor(proc(payload: string): tuple[ok: bool, plaintext: string, err: string] {.gcsafe.} =
      (true, "nonce-plaintext", "")
    )

    let processed = c.processServerPacket("""{"op":"nonce_proof","encrypted_nonce":"enc"}""")
    check processed.ok
    check processed.action.kind == raaSendPacket

    let packetJson = parseJson(processed.action.outboundJson)
    check packetJson["op"].getStr() == "nonce_proof"
    check packetJson["proof"].getStr() == nonceProofFromPlaintext("nonce-plaintext")

  test "pending remote init / ticket / login / cancel":
    let c = newRemoteAuthClient()
    c.setDecryptor(proc(payload: string): tuple[ok: bool, plaintext: string, err: string] {.gcsafe.} =
      case payload
      of "enc-user": (true, "42:9999:avatar:carol", "")
      else: (false, "", "unexpected payload")
    )

    let qr = c.processServerPacket("""{"op":"pending_remote_init","fingerprint":"abc123"}""")
    check qr.ok
    check qr.action.kind == raaQrCode
    check qr.action.qrUrl == "https://discordapp.com/ra/abc123"
    check c.lastQrUrl == "https://discordapp.com/ra/abc123"

    let userPkt = c.processServerPacket("""{"op":"pending_ticket","encrypted_user_payload":"enc-user"}""")
    check userPkt.ok
    check userPkt.action.kind == raaUserUpdated
    check userPkt.action.user.userId == "42"
    check userPkt.action.user.username == "carol"

    let loginPkt = c.processServerPacket("""{"op":"pending_login","ticket":"ticket-1"}""")
    check loginPkt.ok
    check loginPkt.action.kind == raaTicketReceived
    check loginPkt.action.ticket == "ticket-1"
    check c.ticket == "ticket-1"

    let cancelPkt = c.processServerPacket("""{"op":"cancel"}""")
    check cancelPkt.ok
    check cancelPkt.action.kind == raaCancel
    check c.closed

  test "unknown op returns error":
    let parsed = parseServerPacket("""{"op":"nope"}""")
    check not parsed.ok
