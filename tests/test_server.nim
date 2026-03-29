import std/[asynchttpserver, unittest]
import appservice/server

suite "appservice server":
  test "extract transaction id":
    check extractTxnId("/_matrix/app/v1/transactions/123") == "123"
    check extractTxnId("/transactions/abc") == "abc"
    check extractTxnId("/other") == ""

  test "parse transaction":
    let body = """
{
  "events": [
    {
      "event_id": "$e1",
      "room_id": "!room:localhost",
      "sender": "@alice:localhost",
      "type": "m.room.message",
      "origin_server_ts": 100,
      "content": {"msgtype": "m.text", "body": "hello"}
    }
  ],
  "de.sorunome.msc2409.ephemeral": [
    {
      "room_id": "!room:localhost",
      "sender": "@alice:localhost",
      "type": "m.typing",
      "origin_server_ts": 101,
      "content": {"user_ids": ["@alice:localhost"]}
    }
  ]
}
"""
    let tx = parseTransaction("tx1", body)
    check tx.transactionId == "tx1"
    check tx.events.len == 1
    check tx.events[0].eventType == "m.room.message"
    check tx.ephemeral.len == 1
    check tx.ephemeral[0].eventType == "m.typing"

  test "auth helper accepts bearer hs_token":
    let decision = authorizeAppserviceRequest(
      newHttpHeaders({"Authorization": "Bearer hs-secret"}),
      "",
      "hs-secret"
    )
    check decision.ok
    check decision.source == aasBearer

  test "auth helper accepts query hs_token fallback":
    let decision = authorizeAppserviceRequest(
      newHttpHeaders(),
      "access_token=hs-secret",
      "hs-secret"
    )
    check decision.ok
    check decision.source == aasQuery

  test "auth helper rejects wrong bearer token":
    let decision = authorizeAppserviceRequest(
      newHttpHeaders({"Authorization": "Bearer wrong"}),
      "",
      "hs-secret"
    )
    check not decision.ok
    check decision.source == aasBearer

  test "auth helper rejects malformed authorization header":
    let decision = authorizeAppserviceRequest(
      newHttpHeaders({"Authorization": "Token hs-secret"}),
      "",
      "hs-secret"
    )
    check not decision.ok
    check decision.source == aasMalformed

  test "auth helper rejects missing auth":
    let decision = authorizeAppserviceRequest(
      newHttpHeaders(),
      "",
      "hs-secret"
    )
    check not decision.ok
    check decision.source == aasMissing

  test "auth helper prefers authorization header over query fallback":
    let malformed = authorizeAppserviceRequest(
      newHttpHeaders({"Authorization": "Token hs-secret"}),
      "access_token=hs-secret",
      "hs-secret"
    )
    check not malformed.ok
    check malformed.source == aasMalformed

    let wrongBearer = authorizeAppserviceRequest(
      newHttpHeaders({"Authorization": "Bearer wrong"}),
      "access_token=hs-secret",
      "hs-secret"
    )
    check not wrongBearer.ok
    check wrongBearer.source == aasBearer
