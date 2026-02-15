## Discord REST client primitives used by bridge runtime flows.

import std/[httpclient, json, os, strutils, uri]

const
  DefaultDiscordApiBase* = "https://discord.com/api/v9"
  DefaultDiscordUserAgent* = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  DefaultDiscordSecChUa* = "\" Not A;Brand\";v=\"99\", \"Chromium\";v=\"141\", \"Google Chrome\";v=\"141\""
  DefaultDiscordSuperProperties* = "eyJvcyI6IldpbmRvd3MiLCJicm93c2VyIjoiQ2hyb21lIiwiZGV2aWNlIjoiIiwic3lzdGVtX2xvY2FsZSI6ImVuLVVTIiwiYnJvd3Nlcl91c2VyX2FnZW50IjoiTW96aWxsYS81LjAgKFdpbmRvd3MgTlQgMTAuMDsgV2luNjQ7IHg2NCkgQXBwbGVXZWJLaXQvNTM3LjM2IChLSFRNTCwgbGlrZSBHZWNrbykgQ2hyb21lLzE0MS4wLjAuMCBTYWZhcmkvNTM3LjM2IiwiYnJvd3Nlcl92ZXJzaW9uIjoiMTQxLjAuMC4wIiwib3NfdmVyc2lvbiI6IjEwIiwicmVmZXJyZXIiOiJodHRwczovL2Rpc2NvcmQuY29tL2NoYW5uZWxzL0BtZSIsInJlZmVycmluZ19kb21haW4iOiJkaXNjb3JkLmNvbSIsInJlZmVycmVyX2N1cnJlbnQiOiIiLCJyZWZlcnJpbmdfZG9tYWluX2N1cnJlbnQiOiIiLCJyZWxlYXNlX2NoYW5uZWwiOiJzdGFibGUiLCJjbGllbnRfYnVpbGRfbnVtYmVyIjo0NTkyMTksImNsaWVudF9ldmVudF9zb3VyY2UiOm51bGx9"

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

proc newDiscordRestClient*(token: string, baseUrl = DefaultDiscordApiBase, userAgent = DefaultDiscordUserAgent): DiscordRestClient =
  DiscordRestClient(
    token: token,
    baseUrl: normalizeBaseUrl(baseUrl),
    userAgent: userAgent,
    http: newHttpClient()
  )

proc buildHeaders(c: DiscordRestClient, includeJsonContentType = true, browserLike = false): HttpHeaders =
  var h = newHttpHeaders()
  h["Authorization"] = c.token
  h["User-Agent"] = c.userAgent
  if includeJsonContentType:
    h["Content-Type"] = "application/json"
  if browserLike:
    h["Accept"] = "*/*"
    h["Origin"] = "https://discord.com"
    h["Accept-Language"] = "en-US,en;q=0.9"
    h["Sec-Ch-Ua"] = DefaultDiscordSecChUa
    h["Sec-Ch-Ua-Mobile"] = "?0"
    h["Sec-Ch-Ua-Platform"] = "\"Windows\""
    h["Sec-Fetch-Dest"] = "empty"
    h["Sec-Fetch-Mode"] = "cors"
    h["Sec-Fetch-Site"] = "same-origin"
    h["X-Debug-Options"] = "bugReporterEnabled"
    h["X-Discord-Locale"] = "en-US"
    h["X-Discord-Timezone"] = "UTC"
    h["X-Super-Properties"] = DefaultDiscordSuperProperties
  h

proc request*(
    c: DiscordRestClient,
    httpMethod: HttpMethod,
    path: string,
    payload: JsonNode = newJNull(),
    browserLike = false
): DiscordRestResult =
  let url = c.baseUrl & path
  var data = ""
  if payload.kind != JNull:
    data = $payload

  c.http.headers = c.buildHeaders(includeJsonContentType = data.len > 0, browserLike = browserLike)
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

proc getUser*(c: DiscordRestClient, userId: string): DiscordRestResult =
  c.request(HttpGet, "/users/" & userId.encodeUrl())

proc getPrivateChannels*(c: DiscordRestClient): DiscordRestResult =
  c.request(HttpGet, "/users/@me/channels")

proc getRelationships*(c: DiscordRestClient): DiscordRestResult =
  c.request(HttpGet, "/users/@me/relationships", browserLike = true)

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

proc createMessageWithFile*(
    c: DiscordRestClient,
    channelId: string,
    contentText: string,
    filePath: string,
    replyToDiscordMessageId: string = ""
): DiscordRestResult =
  if filePath.len == 0 or not fileExists(filePath):
    return (false, 0, newJNull(), "attachment file not found: " & filePath)

  let url = c.baseUrl & "/channels/" & channelId.encodeUrl() & "/messages"
  var payload = %*{}
  if contentText.len > 0:
    payload["content"] = %contentText
  let trimmedReplyTo = replyToDiscordMessageId.strip()
  if trimmedReplyTo.len > 0:
    payload["message_reference"] = %*{
      "message_id": trimmedReplyTo,
      "channel_id": channelId,
      "fail_if_not_exists": false
    }

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
  c.request(HttpDelete, "/users/@me/relationships/" & userId.encodeUrl(), browserLike = true)

proc addFriend*(c: DiscordRestClient, userId: string): DiscordRestResult =
  # DiscordGo sends type=4 to create/send a friend request.
  # Fallback to type=1 for compatibility with incoming request acceptance flows.
  let sent = c.request(HttpPut, "/users/@me/relationships/" & userId.encodeUrl(), %*{"type": 4}, browserLike = true)
  if sent.ok:
    return sent
  if sent.status in [400, 403, 404]:
    return c.request(HttpPut, "/users/@me/relationships/" & userId.encodeUrl(), %*{"type": 1}, browserLike = true)
  sent

proc blockUser*(c: DiscordRestClient, userId: string): DiscordRestResult =
  c.request(HttpPut, "/users/@me/relationships/" & userId.encodeUrl(), %*{"type": 2}, browserLike = true)
