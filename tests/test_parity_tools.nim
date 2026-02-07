import std/[unittest, strutils, sets, tables]

proc parseTsv(path: string): seq[seq[string]] =
  let raw = readFile(path).strip()
  result = @[]
  if raw.len == 0:
    return
  for line in raw.splitLines():
    var cols = line.split('\t')
    while cols.len < 6:
      cols.add("")
    result.add(cols)

proc keyFor(cols: seq[string]): string =
  cols[0] & "\t" & cols[1] & "\t" & cols[2]

suite "parity tooling":
  test "function parity mapping covers full inventory":
    let inventory = parseTsv("docs/go_function_inventory.tsv")
    let parity = parseTsv("docs/parity_functions.tsv")

    check inventory.len > 1
    check parity.len > 1

    check inventory[0].len >= 3
    check parity[0].len >= 6

    check inventory[0][0] == "file"
    check inventory[0][1] == "line"
    check inventory[0][2] == "signature"

    check parity[0][0] == "file"
    check parity[0][1] == "line"
    check parity[0][2] == "signature"
    check parity[0][3] == "status"

    var invKeys = initHashSet[string]()
    for i in 1 ..< inventory.len:
      let cols = inventory[i]
      check cols.len >= 3
      invKeys.incl(cols.keyFor())

    var parityKeys = initHashSet[string]()
    var parityStatuses = initTable[string, string]()
    for i in 1 ..< parity.len:
      let cols = parity[i]
      check cols.len >= 4
      let key = cols.keyFor()
      check not parityKeys.contains(key)
      parityKeys.incl(key)
      parityStatuses[key] = cols[3].strip()

    check invKeys.len == parityKeys.len
    for key in invKeys:
      check parityKeys.contains(key)
      check parityStatuses[key].len > 0
