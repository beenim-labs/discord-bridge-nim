## Discord REST client primitives used by bridge runtime flows.

import std/[httpclient, json, os, strutils, uri]

type
  DiscordRestClient* = ref object
    token*: string
    baseUrl*: string
    userAgent*: string
    http*: HttpClient

  DiscordRestResult* = tuple[ok: bool, status: int, body: JsonNode, err: string]

proc normalizeBaseUrl(base: string): string =
  var b = base.strip()
  if b.endsWith("/"):
    b.setLen(b.len - 1)
  b

proc newDiscordRestClient*(token: string, baseUrl = "https://discord.com/api/v10", userAgent = "DiscordBot (bridge-discord-nim, 0.1.0)"): DiscordRestClient =
  DiscordRestClient(
    token: token,
    baseUrl: normalizeBaseUrl(baseUrl),
    userAgent: userAgent,
    http: newHttpClient()
  )

proc buildHeaders(c: DiscordRestClient): HttpHeaders =
  var h = newHttpHeaders()
  h["Authorization"] = c.token
  h["User-Agent"] = c.userAgent
  h["Content-Type"] = "application/json"
  h

proc request*(c: DiscordRestClient, httpMethod: HttpMethod, path: string, payload: JsonNode = newJNull()): DiscordRestResult =
  let url = c.baseUrl & path
  var data = ""
  if payload.kind != JNull:
    data = $payload

  c.http.headers = c.buildHeaders()
  try:
    let resp = if data.len > 0:
      c.http.request(url, httpMethod, body = data)
    else:
      c.http.request(url, httpMethod)

    let raw = resp.body
    var body = newJNull()
    if raw.len > 0:
      try:
        body = parseJson(raw)
      except CatchableError:
        body = %*{"raw": raw}
    if resp.code.is2xx:
      return (true, int(resp.code), body, "")
    let msg =
      if body.kind == JObject and body.hasKey("message"):
        body["message"].getStr("")
      else:
        raw
    (false, int(resp.code), body, msg)
  except CatchableError as e:
    (false, 0, newJNull(), e.msg)

proc getCurrentUser*(c: DiscordRestClient): DiscordRestResult =
  c.request(HttpGet, "/users/@me")

proc getPrivateChannels*(c: DiscordRestClient): DiscordRestResult =
  c.request(HttpGet, "/users/@me/channels")

proc getGuildChannels*(c: DiscordRestClient, guildId: string): DiscordRestResult =
  c.request(HttpGet, "/guilds/" & guildId.encodeUrl() & "/channels")

proc getChannel*(c: DiscordRestClient, channelId: string): DiscordRestResult =
  c.request(HttpGet, "/channels/" & channelId.encodeUrl())

proc getChannelMessages*(
    c: DiscordRestClient,
    channelId: string,
    limit = 50,
    before = "",
    after = ""
): DiscordRestResult =
  var query: seq[string] = @[]
  let boundedLimit = max(1, min(100, limit))
  query.add("limit=" & $boundedLimit)
  if before.len > 0:
    query.add("before=" & before.encodeUrl())
  if after.len > 0:
    query.add("after=" & after.encodeUrl())
  let suffix = if query.len > 0: "?" & query.join("&") else: ""
  c.request(HttpGet, "/channels/" & channelId.encodeUrl() & "/messages" & suffix)

proc createMessage*(c: DiscordRestClient, channelId: string, content: JsonNode): DiscordRestResult =
  c.request(HttpPost, "/channels/" & channelId.encodeUrl() & "/messages", content)

proc createMessageWithFile*(c: DiscordRestClient, channelId: string, contentText: string, filePath: string): DiscordRestResult =
  if filePath.len == 0 or not fileExists(filePath):
    return (false, 0, newJNull(), "attachment file not found: " & filePath)

  let url = c.baseUrl & "/channels/" & channelId.encodeUrl() & "/messages"
  var payload = %*{}
  if contentText.len > 0:
    payload["content"] = %contentText

  proc sendWithField(fileField: string): DiscordRestResult =
    var multipart = newMultipartData()
    multipart["payload_json"] = $payload
    discard multipart.addFiles([(fileField, filePath)], useStream = true)

    c.http.headers = c.buildHeaders()
    if c.http.headers.hasKey("Content-Type"):
      c.http.headers.del("Content-Type")

    try:
      let resp = c.http.request(url, HttpPost, multipart = multipart)
      let raw = resp.body
      var body = newJNull()
      if raw.len > 0:
        try:
          body = parseJson(raw)
        except CatchableError:
          body = %*{"raw": raw}
      if resp.code.is2xx:
        return (true, int(resp.code), body, "")
      let msg =
        if body.kind == JObject and body.hasKey("message"):
          body["message"].getStr("")
        else:
          raw
      (false, int(resp.code), body, msg)
    except CatchableError as e:
      (false, 0, newJNull(), e.msg)

  let primary = sendWithField("files[0]")
  if primary.ok:
    return primary
  # Compatibility fallback for clients/environments that expect "file".
  let fallback = sendWithField("file")
  if fallback.ok:
    return fallback
  if fallback.err.len > 0:
    return fallback
  primary

proc editMessage*(c: DiscordRestClient, channelId, messageId: string, content: JsonNode): DiscordRestResult =
  c.request(HttpPatch, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl(), content)

proc deleteMessage*(c: DiscordRestClient, channelId, messageId: string): DiscordRestResult =
  c.request(HttpDelete, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl())

proc addReaction*(c: DiscordRestClient, channelId, messageId, emoji: string): DiscordRestResult =
  c.request(HttpPut, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl() & "/reactions/" & emoji.encodeUrl() & "/@me")

proc removeReaction*(c: DiscordRestClient, channelId, messageId, emoji: string): DiscordRestResult =
  c.request(HttpDelete, "/channels/" & channelId.encodeUrl() & "/messages/" & messageId.encodeUrl() & "/reactions/" & emoji.encodeUrl() & "/@me")

proc closePrivateChannel*(c: DiscordRestClient, channelId: string): DiscordRestResult =
  c.request(HttpDelete, "/channels/" & channelId.encodeUrl())

proc removeFriend*(c: DiscordRestClient, userId: string): DiscordRestResult =
  c.request(HttpDelete, "/users/@me/relationships/" & userId.encodeUrl())

proc blockUser*(c: DiscordRestClient, userId: string): DiscordRestResult =
  c.request(HttpPut, "/users/@me/relationships/" & userId.encodeUrl(), %*{"type": 2})
