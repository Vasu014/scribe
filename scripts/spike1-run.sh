#!/bin/bash
# spike1-run.sh — orchestrates the Spike-1 coexistence matrix
# (docs/spikes/spike1.md, SPEC §4.1/§7) via Tools/SpikeHarness.
#
# Modes:
#   --smoke              all 4 combos × 90 s (sanity pass before --full)
#   --full               all 4 combos × 600 s (default)
#   --duration N         override the per-combo duration (seconds)
#   --only <combo>       one combo only, e.g. --only sck-first:vp-on
#   --summarize          read the results file, print table + markdown rows
#
# Combos: sck-first:vp-on  sck-first:vp-off  mic-first:vp-on  mic-first:vp-off
#
# Permissions are preflighted FIRST (harness --probe, up to 3 attempts,
# 30 s apart) — runs never start without TCC grants (results would be
# meaningless). Each combo appends the harness's one-line verdict JSON to
# docs/spikes/spike1-results-machine1.jsonl.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$ROOT/Tools/SpikeHarness"
RESULTS="$ROOT/docs/spikes/spike1-results-machine1.jsonl"
COMBOS="sck-first:vp-on sck-first:vp-off mic-first:vp-on mic-first:vp-off"

MODE="full"
DURATION=""
ONLY=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --smoke)    MODE="smoke" ;;
    --full)     MODE="full" ;;
    --duration) DURATION="${2:?--duration needs a value}"; shift ;;
    --only)     ONLY="${2:?--only needs a combo name}"; shift ;;
    --summarize) MODE="summarize" ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
  shift
done

harness() { (cd "$HARNESS_DIR" && swift run SpikeHarness "$@"); }

duration_for_mode() {
  if [ -n "$DURATION" ]; then echo "$DURATION"
  elif [ "$MODE" = "smoke" ]; then echo 90
  else echo 600
  fi
}

# ---------------------------------------------------------------- preflight

preflight() {
  local attempt rc
  for attempt in 1 2 3; do
    echo "[preflight] permission probe (attempt $attempt/3)…" >&2
    set +e
    harness --probe
    rc=$?
    set -e
    case "$rc" in
      0) echo "[preflight] permissions granted — ready." >&2; return 0 ;;
      10) echo "[preflight] MICROPHONE denied. Grant under System Settings → Privacy & Security → Microphone for the app running this script (quit & reopen it), then wait for the retry." >&2 ;;
      11) echo "[preflight] SCREEN RECORDING not granted. Grant under System Settings → Privacy & Security → Screen Recording for the responsible app (the terminal/editor), quit & reopen it, then wait for the retry." >&2 ;;
      *)  echo "[preflight] probe failed with exit $rc (build error?)." >&2; return 1 ;;
    esac
    if [ "$attempt" -lt 3 ]; then
      echo "[preflight] retrying in 30 s…" >&2
      sleep 30
    fi
  done
  echo "[preflight] PERMISSIONS STILL MISSING after 3 attempts — aborting; NOT starting any runs (ungranted runs produce garbage). Fix TCC and rerun." >&2
  return 1
}

# ---------------------------------------------------------------- combos

run_combo() {
  local combo="$1" dur="$2"
  local order="${combo%%:*}" vp="${combo##*:}"
  local order_flag="sck" vp_flag="on"
  [ "$order" = "mic-first" ] && order_flag="mic"
  [ "$vp" = "vp-off" ] && vp_flag="off"

  local build label json
  build="$(sw_vers -productVersion)"
  label="${combo}@${build}"

  echo "" >&2
  echo "=== combo $label (${dur} s) ===" >&2
  json="$(harness --order "$order_flag" --vp "$vp_flag" --duration "$dur" --label "$label")"

  if [ -z "$json" ]; then
    echo "ERROR: harness emitted no verdict line for $label" >&2
    exit 1
  fi
  printf '%s\n' "$json" >> "$RESULTS"

  python3 - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
status = "OK  " if d["ok"] else "FAIL"
deg = d.get("remoteDegraded") or "-"
notes = "; ".join(d.get("notes", []))[:100]
print(f"[verdict] {status} {d['label']}  mic {d['mic']['buffers']} bufs / maxGap {d['mic']['maxGapSec']}s  "
      f"remote {d['remote']['buffers']} bufs / maxGap {d['remote']['maxGapSec']}s  degraded: {deg}  {notes}")
PY

}

# ---------------------------------------------------------------- summarize

summarize() {
  python3 - "$RESULTS" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path) as f:
        rows = [json.loads(l) for l in f if l.strip()]
except FileNotFoundError:
    print(f"no results yet ({path}) — run a combo first")
    sys.exit(0)

print(f"\n{len(rows)} run(s) in {path}\n")
header = f"{'label':<28} {'ok':<5} {'mic maxGap':>10} {'rem maxGap':>10}  {'degraded':<20} notes"
print(header)
print("-" * len(header))
for r in rows:
    mic, rem = r.get("mic", {}), r.get("remote", {})
    notes = "; ".join(r.get("notes", []))
    srn = r.get("swiftRuntimeNote")
    if srn:
        notes = (notes + "; " + srn).strip("; ")
    print(f"{r['label']:<28} {str(r['ok']):<5} {str(mic.get('maxGapSec')):>10} "
          f"{str(rem.get('maxGapSec')):>10}  {str(r.get('remoteDegraded') or '-'):<20} {notes[:70]}")

print("\nMarkdown rows for the spike1.md matrix:\n")
n = 0
for r in rows:
    n += 1
    combo = r["label"].split("@")[0]
    build = r["label"].split("@", 1)[1] if "@" in r["label"] else ""
    order, vp = combo.split(":")
    so = "SCStream first" if order == "sck-first" else "Engine first"
    vv = "ON" if vp == "vp-on" else "OFF"
    mic, rem = r.get("mic", {}), r.get("remote", {})
    if r["ok"]:
        result = "stable"
    elif rem.get("buffers", 0) < 50:
        result = "remote died"
    elif mic.get("buffers", 0) < 50:
        result = "mic died"
    else:
        result = "unstable"
    bits = []
    if r.get("remoteDegraded"):
        bits.append(str(r["remoteDegraded"]))
    bits += [str(x) for x in r.get("notes", [])]
    if r.get("swiftRuntimeNote"):
        bits.append(str(r["swiftRuntimeNote"]))
    notes = "; ".join(bits).replace("|", "/")[:140]
    print(f"| {n} | {so} | {vv} | Machine 1 | {build} | {result} | {notes} |")
PY
}

# ---------------------------------------------------------------- main

case "$MODE" in
  summarize) summarize; exit 0 ;;
esac

if [ -n "$ONLY" ]; then
  case " $COMBOS " in
    *" $ONLY "*) ;;
    *) echo "unknown combo '$ONLY' (valid: $COMBOS)" >&2; exit 64 ;;
  esac
fi

preflight || { echo "ABORTED: permissions not granted — no runs started." >&2; exit 1; }

DUR="$(duration_for_mode)"
mkdir -p "$(dirname "$RESULTS")"

if [ -n "$ONLY" ]; then
  run_combo "$ONLY" "$DUR"
else
  for combo in $COMBOS; do
    run_combo "$combo" "$DUR"
  done
fi

echo "" >&2
echo "done — verdicts appended to $RESULTS (summarize: scripts/spike1-run.sh --summarize)" >&2
