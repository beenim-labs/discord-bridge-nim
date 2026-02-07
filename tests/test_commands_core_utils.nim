import std/[base64, strutils, unittest]
import bridge/commands/core_utils

proc rawUrlB64(input: string): string =
  var encoded = encode(input)
  encoded = encoded.replace('+', '-').replace('/', '_')
  while encoded.len > 0 and encoded[^1] == '=':
    encoded.setLen(encoded.len - 1)
  encoded

suite "commands core utils":
  test "decodeToken success and base validations":
    let token = rawUrlB64("1234567890") & "." & rawUrlB64("random") & "." & rawUrlB64("checksum")
    let decoded = decodeToken(token)
    check decoded.ok
    check decoded.userId == 1234567890'i64

  test "decodeToken reports part-count and part decoding errors":
    let badParts = decodeToken("abc")
    check not badParts.ok
    check badParts.err.contains("invalid number of parts")

    let badUser = decodeToken("!!!!.AAAA.AAAA")
    check not badUser.ok
    check badUser.err.contains("invalid base64 in user ID part")

    let badRandom = decodeToken(rawUrlB64("123") & ".!!!!.AAAA")
    check not badRandom.ok
    check badRandom.err.contains("invalid base64 in random part")

    let badChecksum = decodeToken(rawUrlB64("123") & "." & rawUrlB64("abc") & ".!!!!")
    check not badChecksum.ok
    check badChecksum.err.contains("invalid base64 in checksum part")

    let badNumber = decodeToken(rawUrlB64("abc") & "." & rawUrlB64("random") & "." & rawUrlB64("checksum"))
    check not badNumber.ok
    check badNumber.err.contains("invalid number in decoded user ID part")

  test "isNumber mirrors Go semantics":
    check isNumber("123456")
    check not isNumber("123x")
    check not isNumber("x123")
    check isNumber("")
