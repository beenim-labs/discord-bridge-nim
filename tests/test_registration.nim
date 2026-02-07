import std/[unittest, os]
import config/config
import appservice/registration

suite "registration":
  test "generate and parse registration":
    let cfg = loadConfig("tests/fixtures/mautrix-discord.sample.yaml")
    let reg = buildRegistration(cfg)

    check reg.id == "discord"
    check reg.url == "http://127.0.0.1:29334"
    check reg.asToken.len == 64
    check reg.hsToken.len == 64
    check reg.senderLocalpart == "discordbot"

    let outPath = "tests/fixtures/test-discord-registration.yaml"
    if fileExists(outPath):
      removeFile(outPath)

    writeRegistration(outPath, cfg, reg)
    check fileExists(outPath)

    let parsed = readRegistration(outPath)
    check parsed.id == reg.id
    check parsed.url == reg.url
    check parsed.senderLocalpart == reg.senderLocalpart

    if fileExists(outPath):
      removeFile(outPath)
