## Minimal structured logging helpers for the bridge.

import std/[times, strformat]

proc nowStamp(): string =
  now().format("yyyy-MM-dd'T'HH:mm:sszzz")

proc info*(msg: string) =
  echo fmt"[{nowStamp()}] [INFO] {msg}"

proc warn*(msg: string) =
  echo fmt"[{nowStamp()}] [WARN] {msg}"

proc err*(msg: string) =
  stderr.writeLine fmt"[{nowStamp()}] [ERROR] {msg}"

proc debug*(msg: string) =
  when defined(debug):
    echo fmt"[{nowStamp()}] [DEBUG] {msg}"
