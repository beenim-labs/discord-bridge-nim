import std/unittest
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
