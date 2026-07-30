#!/bin/bash
# thin_with_plan.sh - apply a persisted thinning plan to an embedded Python, then
# verify by re-running the plan's traced workloads.
#
# Part of the Python-Embedding toolkit. This is the APPLY half of the plan-driven
# workflow:
#
#   1. PLAN  - analyze_python_deps.py --print plan  ->  a committable JSON plan
#   2. APPLY - thin_with_plan.sh --plan <plan.json> ->  performs the removal
#
# The plan lists module names (not absolute paths), so apply resolves them against the
# CURRENT distribution. That makes it idempotent and re-applicable: if a fresh Python
# was installed into the app (wiping a previously thinned dist), just re-run apply with
# the same committed plan to thin it again.
#
# SAFETY MODEL (same as thin_with_closure.sh)
#   - Back up the whole Python dir before touching it.
#   - Delete exactly what the plan names (modules resolved to paths + orphaned dylibs),
#     plus include/ and bytecode and an optional arch slice per the plan's options.
#   - Re-run every trace command recorded in the plan; if any raises
#     ImportError/Traceback, RESTORE the backup and exit non-zero. (Skip with --skip-verify
#     when the workload can't run here, e.g. a committed plan on a different machine.)
#
# USAGE
#   thin_with_plan.sh --python <PYDIR> --plan <plan.json> [--dry-run] [--skip-verify]
#                     [--verify-prepare CMD]
#
# This script knows nothing about how the consuming app is laid out. If a plan's workload
# is a set of entry-point scripts that must be re-run somewhere staged, supply
# --verify-prepare CMD: it runs after the deletions and prints extra analyzer arguments
# (one per line) on stdout - typically --python/--root/--sandbox-profile pointing at a
# copy of the app made post-thinning. Without it, verification runs in place.
#
# Run AFTER (re)installing the app's Python; a reinstall restores the full distribution.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYZER="$SCRIPT_DIR/analyze_python_deps.py"
THINNER="$SCRIPT_DIR/thin_python_distribution.sh"
[ -f "$ANALYZER" ] || { echo "Error: analyze_python_deps.py not found next to this script"; exit 1; }
# Checked as well as ANALYZER: this script runs without `set -e`, so a missing helper
# used to print one line to stderr, skip the include/bytecode/arch work entirely, and
# still report "Success" over a distribution that was only half thinned.
[ -x "$THINNER" ] || { echo "Error: thin_python_distribution.sh not found next to this script"; exit 1; }

PYDIR=""
PLAN=""
VERIFY_PREPARE=""
DRYRUN=false
SKIP_VERIFY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --python)      PYDIR="$2"; shift 2 ;;
        --plan)        PLAN="$2"; shift 2 ;;
        --verify-prepare) VERIFY_PREPARE="$2"; shift 2 ;;
        --dry-run)     DRYRUN=true; shift ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

[ -n "$PYDIR" ] && [ -d "$PYDIR" ] || { echo "Error: --python <dir> required (the embedded Python distribution)"; exit 1; }
[ -n "$PLAN" ] && [ -f "$PLAN" ] || { echo "Error: --plan <plan.json> required (a thinning plan)"; exit 1; }
PYBIN="$PYDIR/bin/python3"
[ -x "$PYBIN" ] || { echo "Error: $PYBIN not found/executable"; exit 1; }

calc_size() { /usr/bin/du -shk "$1" 2>/dev/null | /usr/bin/cut -f1 | /usr/bin/awk '{printf "%.1f MB", $1/1024}'; }

# Read scalar/array fields out of the JSON plan with the embedded interpreter (json
# is always present pre-thinning, and never removed).
plan_get() { "$PYBIN" - "$PLAN" "$1" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
key = sys.argv[2]
def get(d, path):
    for k in path.split("."):
        d = d.get(k) if isinstance(d, dict) else None
    return d
v = get(plan, key)
if isinstance(v, list):
    print("\n".join(str(x) for x in v))
elif isinstance(v, bool):
    print("1" if v else "0")
elif v is not None:
    print(v)
PY
}

ARCH="$(plan_get arch)"
INCLUDE_HEADERS="$(plan_get remove.include_headers)"
BYTECODE="$(plan_get remove.bytecode)"

DYLIBS=()
while IFS= read -r d; do [ -n "$d" ] && DYLIBS+=("$d"); done < <(plan_get remove.dylibs)

# Resolve the plan's module names to deletable paths in THIS distribution.
REMOVABLE_PATHS="$("$PYBIN" "$ANALYZER" --python "$PYDIR" --plan "$PLAN" --print removable-paths)"
REMOVE_COUNT=$(printf '%s\n' "$REMOVABLE_PATHS" | grep -c .)

# Packages removals come ONLY from packages.remove, which the audit leaves empty. So
# this is normally nothing at all, and is non-empty only because a human reviewed an
# orphan candidate and moved it in.
PKG_PATHS="$("$PYBIN" "$ANALYZER" --python "$PYDIR" --plan "$PLAN" --print packages-remove-paths 2>/dev/null)"
PKG_COUNT=$(printf '%s\n' "$PKG_PATHS" | grep -c .)
PKGDIR="$("$PYBIN" -c 'import json,sys;p=json.load(open(sys.argv[1])).get("packages") or {};print(p.get("dir") or "")' "$PLAN" 2>/dev/null)"

echo "Plan   : $PLAN"
echo "Python : $("$PYBIN" --version 2>&1)  ($PYDIR)"
echo "Remove : $REMOVE_COUNT modules"
[ "$PKG_COUNT" -gt 0 ] && echo "         + $PKG_COUNT entry/entries from Packages (explicitly listed in packages.remove)"
[ ${#DYLIBS[@]} -gt 0 ] && echo "         + ${#DYLIBS[@]} orphaned dylib(s): ${DYLIBS[*]}"
[ "$INCLUDE_HEADERS" = "1" ] && echo "         + include/ headers"
[ "$BYTECODE" = "1" ] && echo "         + bytecode (.pyc)"
[ -n "$ARCH" ] && echo "         + slice to single arch -> $ARCH"

if $DRYRUN; then
    echo
    echo "=== DRY RUN - module paths that would be removed (top 40) ==="
    printf '%s\n' "$REMOVABLE_PATHS" | sed "s#^$PYDIR/##" | sort | head -40
    [ "$REMOVE_COUNT" -gt 40 ] && echo "  ... ($((REMOVE_COUNT - 40)) more)"
    echo
    echo "Current size: $(calc_size "$PYDIR")  (run without --dry-run to apply)"
    exit 0
fi

BACKUP="${PYDIR%/}.thinbak"
PKGDIR_BAK="${PKGDIR%/}.thinbak"

# An existing backup means a previous run died between "delete" and "verify". The live
# dist is then already thinned and the backup is the ONLY pristine copy - overwriting it
# here would back up the damaged tree and destroy the good one, silently, while
# reporting success. Refuse instead, and say how to recover.
if [ -e "$BACKUP" ]; then
    echo "Error: a backup already exists at $BACKUP"
    echo "A previous apply did not finish, so the live distribution may be half-thinned"
    echo "and this backup is the only pristine copy. Restore it first:"
    echo "  rm -rf \"$PYDIR\" && mv \"$BACKUP\" \"$PYDIR\""
    [ -n "$PKGDIR" ] && [ -e "$PKGDIR_BAK" ] && \
        echo "  rm -rf \"$PKGDIR\" && mv \"$PKGDIR_BAK\" \"$PKGDIR\""
    exit 1
fi

# Installed BEFORE anything is deleted. Previously the signal traps went up only just
# before verification, so Ctrl-C during the delete loop left a half-thinned dist and no
# word about the backup that could undo it.
restore() {
    /bin/rm -rf "$PYDIR"
    /bin/mv "$BACKUP" "$PYDIR"
    if [ -n "${PKG_BACKUP:-}" ] && [ -d "$PKG_BACKUP" ]; then
        /bin/rm -rf "$PKGDIR"
        /bin/mv "$PKG_BACKUP" "$PKGDIR"
    fi
    INTERRUPTED=false
}

INTERRUPTED=true
on_exit() {
    [ -n "${VWORK:-}" ] && /bin/rm -rf "$VWORK"
    if $INTERRUPTED && [ -d "$BACKUP" ]; then
        echo
        echo "Interrupted with a backup still on disk. The distribution may be partly"
        echo "thinned. Restore it with:"
        echo "  rm -rf \"$PYDIR\" && mv \"$BACKUP\" \"$PYDIR\""
    fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo
echo "Backing up -> $BACKUP"
/bin/cp -Rp "$PYDIR" "$BACKUP" || { echo "Backup failed; aborting."; exit 1; }
BEFORE="$(calc_size "$PYDIR")"

# Packages is a separate tree from the interpreter, so it needs its own backup before
# anything is taken out of it - restoring $PYDIR would not put it back.
PKG_BACKUP=""
if [ "$PKG_COUNT" -gt 0 ] && [ -n "$PKGDIR" ] && [ -d "$PKGDIR" ]; then
    PKG_BACKUP="$PKGDIR_BAK"
    [ -e "$PKG_BACKUP" ] && { echo "Error: $PKG_BACKUP already exists; restore it first."; exit 1; }
    /bin/cp -Rp "$PKGDIR" "$PKG_BACKUP" || { echo "Packages backup failed; aborting."; exit 1; }
    echo "Backing up -> $PKG_BACKUP"
fi

echo "Deleting $REMOVE_COUNT out-of-closure modules..."
printf '%s\n' "$REMOVABLE_PATHS" | while IFS= read -r pth; do
    [ -n "$pth" ] && /bin/rm -rf "$pth"
done
for d in ${DYLIBS[@]+"${DYLIBS[@]}"}; do
    if [ -e "$PYDIR/$d" ]; then echo "  removing orphaned $d"; /bin/rm -f "$PYDIR/$d"; fi
done

if [ "$PKG_COUNT" -gt 0 ]; then
    echo "Deleting $PKG_COUNT reviewed entry/entries from Packages..."
    printf '%s\n' "$PKG_PATHS" | while IFS= read -r pth; do
        [ -n "$pth" ] && { echo "  removing $(/usr/bin/basename "$pth")"; /bin/rm -rf "$pth"; }
    done
fi

if [ "$INCLUDE_HEADERS" = "1" ] || [ "$BYTECODE" = "1" ]; then
    COMPONENTS=()
    [ "$INCLUDE_HEADERS" = "1" ] && COMPONENTS+=("include")
    [ "$BYTECODE" = "1" ] && COMPONENTS+=("pyc")
    echo "Removing ${COMPONENTS[*]}..."
    "$THINNER" "$PYDIR" ${COMPONENTS[@]+"${COMPONENTS[@]}"} >/dev/null \
        || { echo "Error: removing ${COMPONENTS[*]} failed; restoring."; restore; exit 1; }
fi
if [ -n "$ARCH" ]; then
    echo "Slicing universal Mach-O -> $ARCH..."
    # Unchecked, this silently left a universal binary behind while the plan recorded a
    # single-arch app - a claim nobody could see was false.
    "$THINNER" --arch "$ARCH" "$PYDIR" >/dev/null \
        || { echo "Error: arch slicing failed; restoring."; restore; exit 1; }
fi

# --- VERIFY: re-run every traced workload; any import failure -> restore + fail ---
# Verification runs in analyze_python_deps.py (Python subprocess timeouts, exit-code
# aware) - NOT a `timeout` binary, which macOS lacks. It must be driven by a FULL
# interpreter: the just-thinned one may have lost json/argparse and could not run the
# analyzer. The backup is that full interpreter (same version); the traces themselves
# still run under the thinned $PYBIN.
VWORK=""

if $SKIP_VERIFY; then
    echo
    echo "Skipping verification (--skip-verify)."
else
    echo
    echo "Verifying: re-running traced workload(s) against the thinned interpreter..."
    VERIFY_PY="$BACKUP/bin/python3"
    [ -x "$VERIFY_PY" ] || VERIFY_PY="/usr/bin/python3"
    VARGS=(--plan "$PLAN" --verify)
    VERIFY_PYDIR="$PYDIR"

    # A plan whose workload is a set of ENTRY POINT SCRIPTS has to re-run them, and only
    # the caller knows how to stage that safely - which directory is the app root, where
    # its interpreter and dependencies sit inside it, what a sandbox profile for it needs
    # to allow. So the caller supplies a hook instead of this script guessing a layout.
    #
    # --verify-prepare CMD runs CMD after the deletions and reads extra analyzer
    # arguments from its stdout, one per line, e.g.
    #     --python /tmp/x/App/py
    #     --root /tmp/x/App
    #     --sandbox-profile /tmp/x/p.sb
    # Anything CMD stages (typically a copy of the app, made AFTER thinning so it shares
    # the thinned interpreter) is its own to clean up.
    #
    # Without the hook, verification runs in place against $PYDIR. That is the whole
    # story for an imports-only plan: its workload is a generated import probe, which
    # has no app layout to reproduce.
    if [ -n "$VERIFY_PREPARE" ]; then
        # eval, not bare expansion. The hook is a COMMAND LINE, so its producer quotes
        # arguments that contain spaces - and an unquoted $VERIFY_PREPARE word-splits
        # without quote removal, leaving the quotes as literal characters and splitting
        # the path anyway. Measured: an app path with a space made the hook exit 2 and
        # the apply abort-and-restore on every run, so the app could never be thinned.
        # Stderr is NOT discarded: the hook's own diagnostic is the only clue to why.
        if ! PREP_OUT="$(eval "$VERIFY_PREPARE")"; then
            echo "Error: --verify-prepare command failed; cannot verify."; restore; exit 1
        fi
        PREP_ARGS=()
        while IFS= read -r line; do
            [ -n "$line" ] && PREP_ARGS+=("$line")
        done <<< "$PREP_OUT"
        if [ ${#PREP_ARGS[@]} -gt 0 ]; then
            VARGS+=("${PREP_ARGS[@]}")
            # The hook may override --python; let its value win by appending ours first.
            case " ${PREP_ARGS[*]} " in
                *" --python "*) VERIFY_PYDIR="" ;;
            esac
            echo "  (verification staged by --verify-prepare)"
        fi
    fi
    [ -n "$VERIFY_PYDIR" ] && VARGS=(--python "$VERIFY_PYDIR" "${VARGS[@]}")
    if ! "$VERIFY_PY" "$ANALYZER" "${VARGS[@]}"; then
        echo
        echo "Verification FAILED - the plan removed a module a traced path needs."
        echo "Restoring backup..."
        restore
        echo "Restored. Edit the plan's remove.modules (keep the missing one) or re-plan, then retry."
        exit 1
    fi
fi

# Verified (or deliberately skipped): the backups have done their job and the EXIT
# handler must stop advertising a restore that is no longer needed or possible.
INTERRUPTED=false
/bin/rm -rf "$BACKUP"
[ -n "$PKG_BACKUP" ] && /bin/rm -rf "$PKG_BACKUP"
AFTER="$(calc_size "$PYDIR")"
echo
echo "Success. Embedded Python: $BEFORE -> $AFTER"
