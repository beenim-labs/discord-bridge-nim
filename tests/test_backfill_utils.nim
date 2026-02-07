import std/unittest
import bridge/backfill_utils

suite "backfill utils":
  test "deterministic event id matches stable sha256/base64url vector":
    let evt = deterministicEventID("!portal:test", "12345", "main")
    check evt == "$YIpmAT1gGhgpLhar39e3-MVvnWYMna3smRoXy2VMR7A:discord.com"

  test "message id comparison and backfill decision":
    check compareMessageIDs("123", "123") == 0
    check compareMessageIDs("99", "100") == -1
    check compareMessageIDs("100", "99") == 1
    check compareMessageIDs("100", "101") == -1
    check compareMessageIDs("101", "100") == 1
    check shouldBackfill("100", "101")
    check not shouldBackfill("101", "101")
    check not shouldBackfill("102", "101")

  test "message slice interface behavior":
    var items: MessageSlice = @[
      BackfillMessageRef(id: "200"),
      BackfillMessageRef(id: "100"),
      BackfillMessageRef(id: "150")
    ]
    check items.len() == 3
    check not items.less(0, 1)
    items.swap(0, 1)
    check items[0].id == "100"
    check items[1].id == "200"

    items.sortByDiscordID()
    check items[0].id == "100"
    check items[1].id == "150"
    check items[2].id == "200"
