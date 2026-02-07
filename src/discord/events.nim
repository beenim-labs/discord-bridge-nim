## Discord gateway payload parsing helpers.

import std/json

type
  GatewayOp* = enum
    goDispatch = 0
    goHeartbeat = 1
    goIdentify = 2
    goResume = 6
    goReconnect = 7
    goInvalidSession = 9
    goHello = 10
    goHeartbeatAck = 11

  GatewayIncoming* = object
    op*: int
    seq*: int64
    eventType*: string
    data*: JsonNode
    raw*: JsonNode

proc parseGatewayIncoming*(payload: string): tuple[ok: bool, evt: GatewayIncoming, err: string] =
  var root: JsonNode = newJObject()
  try:
    root = parseJson(payload)
  except CatchableError as e:
    return (false, GatewayIncoming(), "invalid gateway JSON: " & e.msg)

  if root.kind != JObject:
    return (false, GatewayIncoming(), "gateway payload must be object")
  if not root.hasKey("op"):
    return (false, GatewayIncoming(), "gateway payload missing op")

  var seqVal = 0'i64
  if root.hasKey("s") and root["s"].kind in {JInt, JFloat}:
    seqVal = root["s"].getBiggestInt().int64

  (
    true,
    GatewayIncoming(
      op: root["op"].getInt(),
      seq: seqVal,
      eventType: if root.hasKey("t"): root["t"].getStr() else: "",
      data: if root.hasKey("d"): root["d"] else: newJNull(),
      raw: root
    ),
    ""
  )
