## OpenSSL-backed keygen/decrypt helpers for Discord remote auth.

import std/[base64, strutils, openssl]

type
  RemoteAuthKeypair* = ref object
    pkey: EVP_PKEY
    encodedPublicKey: string

proc EVP_PKEY_CTX_new_id(id: cint, e: ENGINE): EVP_PKEY_CTX {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_keygen_init(ctx: EVP_PKEY_CTX): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_keygen(ctx: EVP_PKEY_CTX, ppkey: ptr EVP_PKEY): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_encrypt_init(ctx: EVP_PKEY_CTX): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_encrypt(ctx: EVP_PKEY_CTX, outBuf: ptr cuchar, outLen: ptr csize_t, inBuf: ptr cuchar, inLen: csize_t): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_decrypt_init(ctx: EVP_PKEY_CTX): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_decrypt(ctx: EVP_PKEY_CTX, outBuf: ptr cuchar, outLen: ptr csize_t, inBuf: ptr cuchar, inLen: csize_t): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_CTX_ctrl(ctx: EVP_PKEY_CTX, keytype, optype, cmd, p1: cint, p2: pointer): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_PKEY_CTX_ctrl_str(ctx: EVP_PKEY_CTX, name, value: cstring): cint {.cdecl, dynlib: DLLUtilName, importc.}

proc i2d_PUBKEY(a: EVP_PKEY, pp: ptr ptr cuchar): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc d2i_PUBKEY(a: ptr EVP_PKEY, pp: ptr ptr cuchar, len: clong): EVP_PKEY {.cdecl, dynlib: DLLUtilName, importc.}

const
  EVP_PKEY_OP_KEYGEN = (1 shl 2)
  EVP_PKEY_OP_TYPE_CRYPT = (1 shl 9) or (1 shl 10)
  EVP_PKEY_ALG_CTRL = 0x1000

  EVP_PKEY_CTRL_RSA_PADDING = EVP_PKEY_ALG_CTRL + 1
  EVP_PKEY_CTRL_RSA_KEYGEN_BITS = EVP_PKEY_ALG_CTRL + 3
  EVP_PKEY_CTRL_RSA_MGF1_MD = EVP_PKEY_ALG_CTRL + 5
  EVP_PKEY_CTRL_RSA_OAEP_MD = EVP_PKEY_ALG_CTRL + 9

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc decodeRawStdBase64(raw: string): tuple[ok: bool, data: seq[byte], err: string] =
  var normalized = raw.strip()
  while normalized.len mod 4 != 0:
    normalized.add('=')
  try:
    (true, stringToBytes(decode(normalized)), "")
  except CatchableError as e:
    (false, @[], "base64 decode failed: " & e.msg)

proc encodeRawStdBase64(data: openArray[byte]): string =
  result = encode(bytesToString(data))
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

proc setRsaCtrlStr(ctx: EVP_PKEY_CTX, name, value: string): bool =
  EVP_PKEY_CTX_ctrl_str(ctx, name.cstring, value.cstring) > 0

proc setRsaKeygenBits(ctx: EVP_PKEY_CTX, bits: cint): bool =
  (
    EVP_PKEY_CTX_ctrl(
      ctx,
      EVP_PKEY_RSA.cint,
      EVP_PKEY_OP_KEYGEN.cint,
      EVP_PKEY_CTRL_RSA_KEYGEN_BITS.cint,
      bits,
      nil
    ) > 0
  ) or setRsaCtrlStr(ctx, "rsa_keygen_bits", $bits)

proc setRsaPadding(ctx: EVP_PKEY_CTX, padding: cint): bool =
  (
    EVP_PKEY_CTX_ctrl(
      ctx,
      EVP_PKEY_RSA.cint,
      -1,
      EVP_PKEY_CTRL_RSA_PADDING.cint,
      padding,
      nil
    ) > 0
  ) or setRsaCtrlStr(ctx, "rsa_padding_mode", "oaep")

proc setRsaOaepMd(ctx: EVP_PKEY_CTX, md: EVP_MD): bool =
  (
    EVP_PKEY_CTX_ctrl(
      ctx,
      EVP_PKEY_RSA.cint,
      EVP_PKEY_OP_TYPE_CRYPT.cint,
      EVP_PKEY_CTRL_RSA_OAEP_MD.cint,
      0,
      cast[pointer](md)
    ) > 0
  ) or setRsaCtrlStr(ctx, "rsa_oaep_md", "sha256")

proc setRsaMgf1Md(ctx: EVP_PKEY_CTX, md: EVP_MD): bool =
  (
    EVP_PKEY_CTX_ctrl(
      ctx,
      EVP_PKEY_RSA.cint,
      EVP_PKEY_OP_TYPE_CRYPT.cint,
      EVP_PKEY_CTRL_RSA_MGF1_MD.cint,
      0,
      cast[pointer](md)
    ) > 0
  ) or setRsaCtrlStr(ctx, "rsa_mgf1_md", "sha256")

proc close*(kp: RemoteAuthKeypair) =
  if kp == nil:
    return
  if kp.pkey != nil:
    EVP_PKEY_free(kp.pkey)
    kp.pkey = nil

proc encodedPublicKeyRawStd*(kp: RemoteAuthKeypair): string =
  if kp == nil:
    return ""
  kp.encodedPublicKey

proc newRemoteAuthKeypair*(): tuple[ok: bool, kp: RemoteAuthKeypair, err: string] =
  var ctx: EVP_PKEY_CTX = nil
  var pkey: EVP_PKEY = nil
  var pubLen = 0
  try:
    ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA.cint, nil)
    if ctx == nil:
      return (false, nil, "failed to allocate EVP keygen context")
    defer:
      if ctx != nil:
        EVP_PKEY_CTX_free(ctx)

    if EVP_PKEY_keygen_init(ctx) != 1:
      return (false, nil, "EVP_PKEY_keygen_init failed")
    if not setRsaKeygenBits(ctx, 2048):
      return (false, nil, "failed to set RSA keygen bits")
    if EVP_PKEY_keygen(ctx, addr pkey) != 1 or pkey == nil:
      return (false, nil, "EVP_PKEY_keygen failed")

    pubLen = i2d_PUBKEY(pkey, nil)
    if pubLen <= 0:
      EVP_PKEY_free(pkey)
      return (false, nil, "i2d_PUBKEY failed")

    var pubBytes = newSeq[byte](pubLen)
    var pubWritePtr = cast[ptr cuchar](addr pubBytes[0])
    if i2d_PUBKEY(pkey, addr pubWritePtr) <= 0:
      EVP_PKEY_free(pkey)
      return (false, nil, "i2d_PUBKEY encode failed")

    let kp = RemoteAuthKeypair(
      pkey: pkey,
      encodedPublicKey: encodeRawStdBase64(pubBytes)
    )
    (true, kp, "")
  except CatchableError as e:
    if pkey != nil:
      EVP_PKEY_free(pkey)
    (false, nil, "failed to generate remoteauth keypair: " & e.msg)

proc applyRsaOaepSha256(ctx: EVP_PKEY_CTX): tuple[ok: bool, err: string] =
  if not setRsaPadding(ctx, RSA_PKCS1_OAEP_PADDING.cint):
    return (false, "failed to set RSA padding")
  discard setRsaOaepMd(ctx, EVP_sha256())
  discard setRsaMgf1Md(ctx, EVP_sha256())
  (true, "")

proc decryptPayload*(kp: RemoteAuthKeypair, b64Payload: string): tuple[ok: bool, plaintext: string, err: string] {.gcsafe.} =
  if kp == nil or kp.pkey == nil:
    return (false, "", "missing keypair")

  let decoded = decodeRawStdBase64(b64Payload)
  if not decoded.ok:
    return (false, "", decoded.err)

  var ctx: EVP_PKEY_CTX = nil
  try:
    ctx = EVP_PKEY_CTX_new(kp.pkey, nil)
    if ctx == nil:
      return (false, "", "EVP_PKEY_CTX_new failed")
    defer:
      if ctx != nil:
        EVP_PKEY_CTX_free(ctx)

    if EVP_PKEY_decrypt_init(ctx) != 1:
      return (false, "", "EVP_PKEY_decrypt_init failed")
    let oaep = applyRsaOaepSha256(ctx)
    if not oaep.ok:
      return (false, "", oaep.err)

    var outLen: csize_t = 0
    let inPtr = if decoded.data.len > 0: cast[ptr cuchar](unsafeAddr decoded.data[0]) else: cast[ptr cuchar](nil)
    if EVP_PKEY_decrypt(ctx, nil, addr outLen, inPtr, csize_t(decoded.data.len)) != 1 or outLen == 0:
      return (false, "", "EVP_PKEY_decrypt size probe failed")

    var plaintext = newSeq[byte](int(outLen))
    if EVP_PKEY_decrypt(ctx, cast[ptr cuchar](addr plaintext[0]), addr outLen, inPtr, csize_t(decoded.data.len)) != 1:
      return (false, "", "EVP_PKEY_decrypt failed")
    if int(outLen) < plaintext.len:
      plaintext.setLen(int(outLen))

    (true, bytesToString(plaintext), "")
  except CatchableError as e:
    (false, "", "decrypt failed: " & e.msg)

proc encryptWithPublicKeyRawStd*(encodedPublicKey, plaintext: string): tuple[ok: bool, encryptedPayload: string, err: string] =
  let decoded = decodeRawStdBase64(encodedPublicKey)
  if not decoded.ok:
    return (false, "", decoded.err)

  var pubKey: EVP_PKEY = nil
  var pubPtr: ptr cuchar = if decoded.data.len > 0: cast[ptr cuchar](unsafeAddr decoded.data[0]) else: cast[ptr cuchar](nil)
  var ctx: EVP_PKEY_CTX = nil
  try:
    pubKey = d2i_PUBKEY(nil, addr pubPtr, clong(decoded.data.len))
    if pubKey == nil:
      return (false, "", "d2i_PUBKEY failed")
    defer:
      if pubKey != nil:
        EVP_PKEY_free(pubKey)

    ctx = EVP_PKEY_CTX_new(pubKey, nil)
    if ctx == nil:
      return (false, "", "EVP_PKEY_CTX_new failed")
    defer:
      if ctx != nil:
        EVP_PKEY_CTX_free(ctx)

    if EVP_PKEY_encrypt_init(ctx) != 1:
      return (false, "", "EVP_PKEY_encrypt_init failed")
    let oaep = applyRsaOaepSha256(ctx)
    if not oaep.ok:
      return (false, "", oaep.err)

    let plainBytes = stringToBytes(plaintext)
    let inPtr = if plainBytes.len > 0: cast[ptr cuchar](unsafeAddr plainBytes[0]) else: cast[ptr cuchar](nil)

    var outLen: csize_t = 0
    if EVP_PKEY_encrypt(ctx, nil, addr outLen, inPtr, csize_t(plainBytes.len)) != 1 or outLen == 0:
      return (false, "", "EVP_PKEY_encrypt size probe failed")

    var encrypted = newSeq[byte](int(outLen))
    if EVP_PKEY_encrypt(ctx, cast[ptr cuchar](addr encrypted[0]), addr outLen, inPtr, csize_t(plainBytes.len)) != 1:
      return (false, "", "EVP_PKEY_encrypt failed")
    if int(outLen) < encrypted.len:
      encrypted.setLen(int(outLen))

    (true, encode(bytesToString(encrypted)), "")
  except CatchableError as e:
    (false, "", "encrypt failed: " & e.msg)
