#!/usr/bin/env bash
# iOS build check: xcodebuild + stdout parsing (no xcresulttool)
# Outputs under .build/: build.log, build_issues.txt, build.json, build.xcresult, DerivedData/
set -uo pipefail

print_usage() {
  cat <<'USAGE'
Usage:
  bash scripts/ios_build_check.sh --project "YourApp.xcodeproj" [--scheme Name]
                                  [--sdk iphonesimulator|iphoneos]
                                  [--no-sign]
                                  [--list-schemes]
                                  [--clean | --clean-derived | --clean-all]
  or
  bash scripts/ios_build_check.sh --workspace "YourApp.xcworkspace" --scheme "Name" [options]

Clean options (choose one):
  --clean          Run 'xcodebuild clean' before build (default if none specified)
  --clean-derived  Remove .build/DerivedData before build
  --clean-all      Remove entire .build/ before build (slowest, most deterministic)

Outputs (in .build/):
  build.log, build_issues.txt, build.json, build.xcresult, DerivedData/
USAGE
}

PROJECT=""; WORKSPACE=""; SCHEME=""
SDK="iphonesimulator"; NOSIGN=0; LIST=0
DO_CLEAN="clean"   # default minimal clean

OUTDIR=".build"
DERIVED="$OUTDIR/DerivedData"
RESULT="$OUTDIR/build.xcresult"
CLEAN_RESULT="$OUTDIR/clean.xcresult"
LOG="$OUTDIR/build.log"
TXT_OUT="$OUTDIR/build_issues.txt"
JSON_OUT="$OUTDIR/build.json"

mkdir -p "$OUTDIR"
STATUS=99  # init

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)         PROJECT="${2:-}"; shift 2;;
    --workspace)       WORKSPACE="${2:-}"; shift 2;;
    --scheme)          SCHEME="${2:-}"; shift 2;;
    --sdk)             SDK="${2:-}"; shift 2;;
    --no-sign)         NOSIGN=1; shift;;
    --list-schemes)    LIST=1; shift;;
    --clean)           DO_CLEAN="clean"; shift;;
    --clean-derived)   DO_CLEAN="clean-derived"; shift;;
    --clean-all)       DO_CLEAN="clean-all"; shift;;
    -h|--help)         print_usage; exit 0;;
    *) echo "Unknown option: $1"; print_usage; exit 2;;
  esac
done

# --- basic checks ---
if [[ -z "$PROJECT" && -z "$WORKSPACE" ]]; then
  echo "Error: specify --project or --workspace"; exit 2
fi
if [[ -n "$PROJECT" && ! -e "$PROJECT" ]]; then
  echo "Error: project not found: $PROJECT"; exit 2
fi
if [[ -n "$WORKSPACE" && ! -e "$WORKSPACE" ]]; then
  echo "Error: workspace not found: $WORKSPACE"; exit 2
fi

# --- CLEAN START (prevent stale artifacts) ---
if [[ "$DO_CLEAN" == "clean-all" ]]; then
  rm -rf "$OUTDIR"
  mkdir -p "$OUTDIR"
elif [[ "$DO_CLEAN" == "clean-derived" ]]; then
  rm -rf "$DERIVED"
fi
# Always start with empty outputs and fresh result bundle placeholders
: > "$LOG"
: > "$TXT_OUT"
: > "$JSON_OUT"
rm -rf "$RESULT" "$CLEAN_RESULT"

# --- scheme detection ---
detect_scheme() {
  local base shared_dir user_dir s
  if [[ -n "$WORKSPACE" ]]; then
    base="$(pwd)/$(basename "$WORKSPACE")"
  else
    base="$(pwd)/$(basename "$PROJECT")"
  fi
  shared_dir="${base}/xcshareddata/xcschemes"
  user_dir="${base}/xcuserdata"

  if [[ -d "$shared_dir" ]]; then
    s=$(grep -hPo '(?<=<Scheme name=").*?(?=")' "$shared_dir"/*.xcscheme 2>/dev/null | head -n1 || true)
    [[ -n "$s" ]] && { echo "$s"; return 0; }
  fi
  if [[ -d "$user_dir" ]]; then
    s=$(grep -hPo '(?<=<Scheme name=").*?(?=")' "$user_dir"/*/xcschemes/"*.xcscheme" 2>/dev/null | head -n1 || true)
    [[ -n "$s" ]] && { echo "$s"; return 0; }
  fi

  local tmp; tmp="$(mktemp)"
  if [[ -n "$WORKSPACE" ]]; then
    xcodebuild -list -workspace "$WORKSPACE" >"$tmp" 2>/dev/null || true
  else
    xcodebuild -list -project "$PROJECT" >"$tmp" 2>/dev/null || true
  fi
  s=$(awk '/Schemes:/{flag=1;next}/^$/{flag=0}flag{print $0}' "$tmp" | head -n1 | xargs || true)
  rm -f "$tmp"
  [[ -n "$s" ]] && { echo "$s"; return 0; }
  return 1
}

if [[ $LIST -eq 1 ]]; then
  echo "== Schemes =="
  if [[ -n "$WORKSPACE" ]]; then
    xcodebuild -list -workspace "$WORKSPACE" || true
  else
    xcodebuild -list -project "$PROJECT" || true
  fi
  cand=$(detect_scheme || true)
  [[ -n "$cand" ]] && { echo; echo "Candidate: $cand"; }
  exit 0
fi

if [[ -z "$SCHEME" ]]; then
  SCHEME="$(detect_scheme || true)"
  if [[ -z "$SCHEME" ]]; then
    echo "Error: no scheme found. In Xcode: Product > Scheme > Manage Schemes… and check 'Shared'."
    exit 3
  fi
  echo "Detected scheme: $SCHEME"
fi

DEST="generic/platform=iOS Simulator"
[[ "$SDK" == "iphoneos" ]] && DEST="generic/platform=iOS"

# --- base xcodebuild args (shared) ---
BASE_CMD=(xcodebuild)
if [[ -n "$WORKSPACE" ]]; then
  BASE_CMD+=(-workspace "$WORKSPACE")
else
  BASE_CMD+=(-project "$PROJECT")
fi
BASE_SHARED=(-scheme "$SCHEME" -configuration Debug -sdk "$SDK" -destination "$DEST" -derivedDataPath "$DERIVED")
if [[ "$SDK" == "iphoneos" && $NOSIGN -eq 1 ]]; then
  BASE_SHARED+=(CODE_SIGNING_ALLOWED=NO)
fi

echo "== Build start =="

# Optional light clean (use a separate result bundle path for clean phase)
if [[ "$DO_CLEAN" == "clean" ]]; then
  echo "-- Running: xcodebuild clean"
  CLEAN_CMD=("${BASE_CMD[@]}" "${BASE_SHARED[@]}" -resultBundlePath "$CLEAN_RESULT" clean)
  printf 'Command: '; printf '%q ' "${CLEAN_CMD[@]}"; echo
  { "${CLEAN_CMD[@]}" 2>&1 | tee -a "$LOG" ; } ; true
  # remove clean result bundle to avoid collision with the build phase
  rm -rf "$CLEAN_RESULT"
fi

# Ensure no leftover bundle before actual build
rm -rf "$RESULT"

# Actual build (dedicated result bundle path)
BUILD_CMD=("${BASE_CMD[@]}" "${BASE_SHARED[@]}" -resultBundlePath "$RESULT" build)
printf 'Command: '; printf '%q ' "${BUILD_CMD[@]}"; echo
{ "${BUILD_CMD[@]}" 2>&1 | tee -a "$LOG" ; } ; STATUS=${PIPESTATUS[0]}

if [[ $STATUS -eq 0 ]]; then
  echo "** BUILD SUCCEEDED (exit 0) **"
else
  echo "** BUILD FAILED (exit $STATUS) **"
fi

echo "== Parse build log =="
/usr/bin/env python3 - "$LOG" "$TXT_OUT" "$JSON_OUT" <<'PY'
import re, sys, json, pathlib
log_path, txt_out, json_out = map(pathlib.Path, sys.argv[1:4])
text = log_path.read_text(errors="ignore")

pat = re.compile(r'^(?P<file>/.*?):(?P<line>\d+):(?P<col>\d+):\s+(?P<sev>error|warning|note):\s+(?P<msg>.*)$', re.MULTILINE)
issues = []
seen = set()
for m in pat.finditer(text):
    key = (m.group("file"), m.group("line"), m.group("col"), m.group("sev"), m.group("msg").strip())
    if key in seen:
        continue
    seen.add(key)
    issues.append({
        "file": key[0],
        "line": int(key[1]),
        "column": int(key[2]),
        "severity": key[3],
        "message": key[4],
    })

if not issues:
    txt_out.write_text("No issues found.")
else:
    lines = [f'{i["file"]}:{i["line"]}:{i["column"]}: {i["severity"]}: {i["message"]}' for i in issues]
    txt_out.write_text("\n".join(lines))

json_out.write_text(json.dumps({"issues": issues}, ensure_ascii=False))
PY

echo "Text issues : $TXT_OUT"
echo "JSON issues : $JSON_OUT"
echo "Result bundle: $RESULT"
echo "Log         : $LOG"
echo "== DONE (xcodebuild exit: $STATUS) =="
exit $STATUS
