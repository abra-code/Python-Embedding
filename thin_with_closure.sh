#!/bin/bash
# thin_with_closure.sh - one-shot closure thinning: trace the real workload, then thin
# the embedded Python to that closure and verify, in a single command.
#
# Part of the Python-Embedding toolkit. This is the whitelist counterpart to the
# blacklist thin_python_distribution.sh. It is a thin convenience wrapper over the
# two-phase, plan-driven flow:
#
#   PLAN  : analyze_python_deps.py --print plan    (compute the closure -> a JSON plan)
#   APPLY : thin_with_plan.sh      --plan <plan>    (delete + verify, restore on failure)
#
# This script just runs PLAN into a temporary plan and immediately APPLYs it, so there
# is a single apply/verify engine (thin_with_plan.sh). If you want to review, commit,
# tweak, or re-apply the plan later, generate it yourself:
#
#   "$PYDIR/bin/python3" analyze_python_deps.py --python "$PYDIR" \
#       --trace "..." --static <Scripts dir> [--arch arm64] --print plan > thinning-plan.json
#   ./thin_with_plan.sh --python "$PYDIR" --plan thinning-plan.json
#
# SAFETY MODEL
#   Back up the dist, delete the complement of the traced closure, then re-run every
#   --trace; any ImportError/Traceback restores the backup and exits non-zero. Coverage
#   is the one thing you must get right: pass a --trace for EVERY distinct code path your
#   app runs (each subcommand / mode). Untraced paths are not protected.
#
# USAGE
#   thin_with_closure.sh --python <PYDIR> \
#       --trace "<PYDIR>/bin/watchmedo shell-command --command true /tmp/w" \
#       [--trace "<another real invocation>"]... \
#       [--static <app Scripts dir>]...   # cross-check: app source modules must appear
#       [--keep name,name]                # force-keep (dynamic imports the trace can't see)
#       [--trace-timeout N]               # seconds before a blocking trace is killed (default 6)
#       [--arch arm64|x86_64]             # also slice universal Mach-O to one arch
#       [--dry-run]                       # show what would be removed + projected size, do nothing
#       [--no-extras]                     # do NOT also remove include/ and bytecode
#
# Run it AFTER building the app bundle (a rebuild restores the full Python).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/analyze_python_deps.py"
APPLY="$SCRIPT_DIR/thin_with_plan.sh"
[ -f "$ANALYZER" ] || { echo "Error: analyze_python_deps.py not found next to this script"; exit 1; }
[ -f "$APPLY" ] || { echo "Error: thin_with_plan.sh not found next to this script"; exit 1; }

PYDIR=""
TRACES=()
STATICS=()
SCRIPTDIRS=()
ROOT=""
PROFILE=""
SCRATCH=""
KEEP=""
TIMEOUT="6"
ARCH=""
DRYRUN=false
EXTRAS=true

while [ $# -gt 0 ]; do
    case "$1" in
        --python)        PYDIR="$2"; shift 2 ;;
        --trace)         TRACES+=("$2"); shift 2 ;;
        --auto-trace-scripts) SCRIPTDIRS+=("$2"); shift 2 ;;
        --root)          ROOT="$2"; shift 2 ;;
        --sandbox-profile) PROFILE="$2"; shift 2 ;;
        --scratch)       SCRATCH="$2"; shift 2 ;;
        --static)        STATICS+=("$2"); shift 2 ;;
        --keep)          KEEP="$2"; shift 2 ;;
        --trace-timeout) TIMEOUT="$2"; shift 2 ;;
        --arch)          ARCH="$2"; shift 2 ;;
        --dry-run)       DRYRUN=true; shift ;;
        --no-extras)     EXTRAS=false; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[ -n "$PYDIR" ] && [ -d "$PYDIR" ] || { echo "Error: --python <dir> required (the embedded Python distribution)"; exit 1; }
# Either way of establishing the closure is fine, but one of them is required: with
# neither, the closure is builtins only and the plan removes almost the whole stdlib.
if [ ${#TRACES[@]} -eq 0 ] && [ ${#SCRIPTDIRS[@]} -eq 0 ]; then
    echo "Error: --auto-trace-scripts <dir> (recommended) or --trace <cmd> is required;"
    echo "       without a workload the closure is builtins only."
    exit 1
fi
PYBIN="$PYDIR/bin/python3"
[ -x "$PYBIN" ] || { echo "Error: $PYBIN not found/executable"; exit 1; }

# PLAN: build the analyzer argument list and emit a plan to a temp file.
AARGS=(--python "$PYDIR" --trace-timeout "$TIMEOUT" --arch "$ARCH")
for t in ${TRACES[@]+"${TRACES[@]}"}; do AARGS+=(--trace "$t"); done
for d in ${SCRIPTDIRS[@]+"${SCRIPTDIRS[@]}"}; do AARGS+=(--auto-trace-scripts "$d"); done
for s in ${STATICS[@]+"${STATICS[@]}"}; do AARGS+=(--static "$s"); done
[ -n "$ROOT" ] && AARGS+=(--root "$ROOT" --check-isolation)
[ -n "$PROFILE" ] && AARGS+=(--sandbox-profile "$PROFILE")
[ -n "$SCRATCH" ] && AARGS+=(--scratch "$SCRATCH")
[ -n "$KEEP" ] && AARGS+=(--keep "$KEEP")
$EXTRAS || AARGS+=(--no-extras)

TMPPLAN="$(mktemp -t thinclosure.XXXXXX)"
trap '/bin/rm -f "$TMPPLAN"' EXIT

echo "Computing module closure (tracing real workload)..."
if ! "$PYBIN" "$ANALYZER" "${AARGS[@]}" --print plan > "$TMPPLAN"; then
    echo "Error: closure analysis failed."; exit 1
fi

# APPLY (or preview) via the shared engine. Verification re-runs the same traces, which
# the plan carries. (Run rather than exec so the trap cleans up the temp plan.)
APPLY_ARGS=(--python "$PYDIR" --plan "$TMPPLAN")
$DRYRUN && APPLY_ARGS+=(--dry-run)
"$APPLY" "${APPLY_ARGS[@]}"
exit $?
