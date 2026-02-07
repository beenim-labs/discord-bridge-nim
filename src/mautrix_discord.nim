## mautrix-discord compatible CLI entrypoint implemented in Nim.

import std/[os, strformat, strutils]
import config/config
import bridge/service
import appservice/registration
import common/logging

const
  DefaultConfigPath = "mautrix-discord.yaml"
  DefaultRegistrationPath = "mautrix-discord-registration.yaml"

proc usage() =
  echo "mautrix-discord (Nim rewrite)"
  echo "Usage:"
  echo "  mautrix-discord -g -c <config.yaml> -r <registration.yaml>"
  echo "  mautrix-discord -c <config.yaml> -r <registration.yaml>"

proc main(): int =
  var generateRegistration = false
  var configPath = DefaultConfigPath
  var registrationPath = DefaultRegistrationPath

  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let arg = args[i]
    case arg
    of "-g":
      generateRegistration = true
    of "-h", "--help":
      usage()
      return 0
    of "-c":
      if i + 1 >= args.len:
        err("Missing value for -c")
        return 2
      inc i
      configPath = args[i]
    of "-r":
      if i + 1 >= args.len:
        err("Missing value for -r")
        return 2
      inc i
      registrationPath = args[i]
    else:
      if arg.startsWith("-c="):
        configPath = arg[3 .. ^1]
      elif arg.startsWith("-r="):
        registrationPath = arg[3 .. ^1]
      else:
        discard
    inc i

  if not fileExists(configPath):
    err("Config file not found: " & configPath)
    return 1

  try:
    let cfg = loadConfig(configPath)
    let validation = cfg.validate()
    if not validation.ok:
      err("Config validation failed: " & validation.err)
      return 1

    if generateRegistration:
      let reg = buildRegistration(cfg)
      writeRegistration(registrationPath, cfg, reg)
      info(fmt"Generated registration: {registrationPath}")
      return 0

    if not fileExists(registrationPath):
      err("Registration file not found: " & registrationPath)
      err("Generate one with: mautrix-discord -g -c " & configPath & " -r " & registrationPath)
      return 1

    let svc = initService(configPath, registrationPath)
    try:
      svc.run()
    finally:
      svc.close()
    return 0
  except CatchableError as e:
    err("Startup failed: " & e.msg)
    return 1

when isMainModule:
  quit(main())
