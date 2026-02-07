import std/[unittest, os, strutils, times, json, httpcore]
import config/config
import database/[database, entities, store]
import directmedia/[api, media_id]

proc cleanupDb(path: string) =
  for suffix in ["", "-wal", "-shm"]:
    let p = path & suffix
    if fileExists(p):
      removeFile(p)

proc openTempDb(name: string): tuple[db: BridgeDb, path: string] =
  let dbPath = "tests/fixtures/" & name & "-" & $getTime().toUnix() & "-" & $epochTime().int64 & ".db"
  cleanupDb(dbPath)
  let db = openBridgeDb("file:" & dbPath, "sqlite")
  (db, dbPath)

proc newMediaApi(db: BridgeDb): DirectMediaApi =
  var cfg = defaultConfig()
  cfg.bridge.directMedia.enabled = true
  cfg.bridge.directMedia.serverName = "cdn.local"
  cfg.bridge.directMedia.allowProxy = false
  cfg.bridge.directMedia.serverKey = "direct-media-test-key"
  newDirectMediaApi(cfg, db)

suite "directmedia api":
  test "non-media paths are ignored":
    let opened = openTempDb("dm-none")
    let db = opened.db
    let dbPath = opened.path
    defer:
      db.close()
      cleanupDb(dbPath)

    let dm = newMediaApi(db)
    let res = dm.handleRequest(HttpGet, "/_matrix/provision/v1/ping", "")
    check not res.handled

  test "attachment download redirects to cached source":
    let opened = openTempDb("dm-attachment")
    let db = opened.db
    let dbPath = opened.path
    defer:
      db.close()
      cleanupDb(dbPath)

    let dm = newMediaApi(db)
    let nowTs = getTime().toUnix()
    let exHex = toHex(int(nowTs + 7200), 8)
    let srcUrl = "https://cdn.discordapp.com/attachments/1/2/file.png?ex=" & exHex

    db.insertFile(FileRecord(
      url: srcUrl,
      encrypted: false,
      mxc: "",
      id: "33",
      emojiName: "",
      size: 10,
      width: 0,
      height: 0,
      mimeType: "image/png",
      decryptionInfoJson: "",
      timestampMs: nowTs * 1000
    ))

    let mediaId = newAttachmentMediaID(11'u64, 22'u64, 33'u64)
    let encoded = signedString(mediaId, dm.signatureKey)

    let res = dm.handleRequest(HttpGet, "/_matrix/media/v3/download/cdn.local/" & encoded, "")
    check res.handled
    check res.code == Http307
    check res.headers.getOrDefault("Location") == srcUrl
    check res.headers.getOrDefault("Cache-Control").startsWith("public, max-age=")

  test "wrong homeserver returns M_NOT_FOUND":
    let opened = openTempDb("dm-host")
    let db = opened.db
    let dbPath = opened.path
    defer:
      db.close()
      cleanupDb(dbPath)

    let dm = newMediaApi(db)
    let mediaId = EmojiMediaData(emojiId: 123'u64, animated: false, name: "blob").wrap()
    let encoded = signedString(mediaId, dm.signatureKey)

    let res = dm.handleRequest(HttpGet, "/_matrix/media/v3/download/other.local/" & encoded, "")
    check res.handled
    check res.code == Http404
    let body = parseJson(res.body)
    check body["errcode"].getStr() == "M_NOT_FOUND"

  test "emoji download URL route works":
    let opened = openTempDb("dm-emoji")
    let db = opened.db
    let dbPath = opened.path
    defer:
      db.close()
      cleanupDb(dbPath)

    let dm = newMediaApi(db)
    let mediaId = EmojiMediaData(emojiId: 555'u64, animated: true, name: "party").wrap()
    let encoded = signedString(mediaId, dm.signatureKey)

    let res = dm.handleRequest(HttpGet, "/_matrix/client/v1/media/download/cdn.local/" & encoded, "")
    check res.handled
    check res.code == Http307
    check res.headers.getOrDefault("Location") == "https://cdn.discordapp.com/emojis/555.gif"

  test "unsupported upload and preview endpoints":
    let opened = openTempDb("dm-upload")
    let db = opened.db
    let dbPath = opened.path
    defer:
      db.close()
      cleanupDb(dbPath)

    let dm = newMediaApi(db)

    let upload = dm.handleRequest(HttpPost, "/_matrix/media/v3/upload", "")
    check upload.handled
    check upload.code == Http501

    let preview = dm.handleRequest(HttpGet, "/_matrix/media/v3/preview_url", "")
    check preview.handled
    check preview.code == Http501

  test "unsupported method and federation version":
    let opened = openTempDb("dm-method")
    let db = opened.db
    let dbPath = opened.path
    defer:
      db.close()
      cleanupDb(dbPath)

    let dm = newMediaApi(db)

    let badMethod = dm.handleRequest(HttpPost, "/_matrix/media/v3/download/cdn.local/x", "")
    check badMethod.handled
    check badMethod.code == Http405

    let version = dm.handleRequest(HttpGet, "/_matrix/federation/v1/version", "")
    check version.handled
    check version.code == Http200
    let parsed = parseJson(version.body)
    check parsed["server"]["name"].getStr() == "discord-bridge-nim"
