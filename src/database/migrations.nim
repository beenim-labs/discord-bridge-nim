## SQL migration loader for local discord-bridge baseline SQL files.

import std/[os, strutils, algorithm]

type
  DbDialect* = enum
    dbSQLite
    dbPostgres

  UpgradeScript* = object
    filename*: string
    path*: string

const UpgradeDir* = "src/database/upgrades"

proc detectDialectFromUri*(uri, dbType: string): DbDialect =
  let lowerUri = uri.toLowerAscii()
  let lowerType = dbType.toLowerAscii()
  if lowerType.contains("postgres") or lowerUri.startsWith("postgres://") or lowerUri.startsWith("postgresql://"):
    return dbPostgres
  dbSQLite

proc isDialectCompatible(fileName: string, dialect: DbDialect): bool =
  if fileName.contains(".sqlite.sql"):
    return dialect == dbSQLite
  if fileName.contains(".postgres.sql"):
    return dialect == dbPostgres
  true

proc loadUpgradeScripts*(dialect: DbDialect): seq[UpgradeScript] =
  result = @[]
  if not dirExists(UpgradeDir):
    return

  var files: seq[string] = @[]
  for path in walkFiles(UpgradeDir / "*.sql"):
    files.add(path)
  files.sort(system.cmp[string])

  for path in files:
    let name = extractFilename(path)
    if isDialectCompatible(name, dialect):
      result.add(UpgradeScript(filename: name, path: path))

proc latestRevisionScript*(dialect: DbDialect): UpgradeScript =
  for script in loadUpgradeScripts(dialect):
    if script.filename == "00-latest-revision.sql":
      return script
  UpgradeScript(filename: "", path: "")

proc hasLatestRevision*(dialect: DbDialect): bool =
  let latest = latestRevisionScript(dialect)
  latest.path.len > 0 and fileExists(latest.path)
