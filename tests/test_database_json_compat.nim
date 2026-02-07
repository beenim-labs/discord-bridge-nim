import std/unittest
import database/json_compat

type
  SamplePayload = object
    value: int

suite "database json compat":
  test "untypedNil keeps nil as nil":
    var empty: ref SamplePayload = nil
    let boxed = jsonPtr(empty)
    check boxed.data.isNil
    check untypedNil(empty).isNil

  test "jsonPtr preserves non-nil payload":
    var payload = new SamplePayload
    payload[].value = 42

    let untyped = untypedNil(payload)
    check not untyped.isNil
    check untyped[].value == 42

    let boxed = jsonPtr(payload)
    check not boxed.data.isNil
    check boxed.data[].value == 42
