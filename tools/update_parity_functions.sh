#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INV="$ROOT_DIR/docs/go_function_inventory.tsv"
OUT="$ROOT_DIR/docs/parity_functions.tsv"

if [[ ! -f "$INV" ]]; then
  echo "missing inventory file: $INV" >&2
  exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

if [[ -f "$OUT" ]]; then
  awk -F'\t' '
    NR==FNR {
      if (FNR > 1) {
        key = $1 "\t" $2 "\t" $3
        status[key] = $4
        nimref[key] = $5
        notes[key] = $6
      }
      next
    }
    FNR==1 {
      print "file\tline\tsignature\tstatus\tnim_ref\tnotes"
      next
    }
    {
      key = $1 "\t" $2 "\t" $3
      s = (key in status) ? status[key] : "Pending"
      r = (key in nimref) ? nimref[key] : ""
      n = (key in notes) ? notes[key] : ""
      print $1 "\t" $2 "\t" $3 "\t" s "\t" r "\t" n
    }
  ' "$OUT" "$INV" > "$tmp_file"
else
  awk -F'\t' '
    FNR==1 {
      print "file\tline\tsignature\tstatus\tnim_ref\tnotes"
      next
    }
    {
      print $1 "\t" $2 "\t" $3 "\tPending\t\t"
    }
  ' "$INV" > "$tmp_file"
fi

mv "$tmp_file" "$OUT"
echo "updated $OUT"
