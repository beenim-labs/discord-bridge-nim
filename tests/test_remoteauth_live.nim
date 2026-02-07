import std/[asyncdispatch, unittest]
import remoteauth/[crypto, live_client]

suite "remoteauth live":
  test "crypto keypair encrypt decrypt roundtrip":
    let generated = newRemoteAuthKeypair()
    check generated.ok
    check generated.kp != nil

    if generated.ok and generated.kp != nil:
      defer:
        generated.kp.close()

      let pub = generated.kp.encodedPublicKeyRawStd()
      check pub.len > 0

      let encrypted = encryptWithPublicKeyRawStd(pub, "token-value")
      check encrypted.ok

      if encrypted.ok:
        let decrypted = generated.kp.decryptPayload(encrypted.encryptedPayload)
        check decrypted.ok
        if decrypted.ok:
          check decrypted.plaintext == "token-value"

  test "invalid websocket endpoint maps to connection failure":
    let result = waitFor runRemoteAuthLoginWith(
      timeoutMs = 1000,
      onQrCode = nil,
      endpoints = RemoteAuthEndpoints(
        websocketUrl: "http://invalid-endpoint",
        apiBaseUrl: "https://discord.com/api/v10"
      ),
      ticketLoginFn = proc(ticket: string): tuple[ok: bool, encryptedToken: string, err: string] {.gcsafe.} =
        (false, "", "should not be called")
    )

    check not result.ok
    check result.failure == rafConnection
    check result.err.len > 0
