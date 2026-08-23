#!/bin/bash
# replay_bootstrap.sh
# Locate - or install without administrator authorization - a "replay" binary of
# at least a required version, and print its absolute path on stdout.
#
# "replay" (https://github.com/abra-code/replay) executes a declarative playlist
# of actions, derives an execution DAG from the files each action consumes and
# produces, and (since 2.2) can skip actions whose declared world is unchanged.
# build-embedded-python.sh uses it as an optional build engine.
#
# Why this script exists: the project ships its releases as a macOS .pkg, and
# running the installer needs an authorization prompt. A .pkg is just a xar
# archive, so the payload can be expanded into a private directory instead - no
# prompt, no system-wide side effects, and nothing written outside the build
# tree. That is the default method here. Building from source is the fallback.
#
# All progress goes to stderr. The resolved path is the only thing on stdout, so
# callers can do:  REPLAY_BIN=$(./replay_bootstrap.sh) || exit 1
#
# Usage:
#   ./replay_bootstrap.sh [OPTIONS]
#
# Options:
#   --min-version=X.Y   Minimum acceptable version (default: 2.2)
#   --tools-dir=DIR     Where a bootstrapped copy is kept (default: ./build/tools)
#   --method=METHOD     auto (default), pkg, source, or path
#                       auto   - reuse an installed/bootstrapped binary, else pkg, else source
#                       pkg    - expand the payload of the latest release .pkg (no authorization)
#                       source - git clone + swift build -c release
#                       path   - only accept an already-installed binary, never install
#   --source-dir=DIR    Existing replay checkout to build from instead of cloning
#   --force             Ignore any already-usable binary and bootstrap a fresh one
#   --help              Show this help

set -uo pipefail

RED=$(printf '\033[91m')
GREEN=$(printf '\033[92m')
RESET=$(printf '\033[0m')

MIN_VERSION="2.2"
TOOLS_DIR=""
METHOD="auto"
SOURCE_DIR="${REPLAY_SOURCE_DIR:-}"
FORCE=false

RELEASES_API="https://api.github.com/repos/abra-code/replay/releases/latest"
RELEASES_PAGE="https://github.com/abra-code/replay/releases"
RELEASE_ASSET_PATH="abra-code/replay/releases/download"
SOURCE_REPO="https://github.com/abra-code/replay.git"

# Tools shipped alongside replay in the same payload. replay itself is the only
# one this build needs, but they travel together and cost nothing to keep.
SIBLING_TOOLS=(dispatch gate fingerprint)

show_help() {
    /usr/bin/sed -n '2,34p' "$0" | /usr/bin/sed 's|^# \{0,1\}||'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help ;;
        --min-version=*) MIN_VERSION="${1#*=}" ;;
        --min-version) shift; MIN_VERSION="$1" ;;
        --tools-dir=*) TOOLS_DIR="${1#*=}" ;;
        --tools-dir) shift; TOOLS_DIR="$1" ;;
        --method=*) METHOD="${1#*=}" ;;
        --method) shift; METHOD="$1" ;;
        --source-dir=*) SOURCE_DIR="${1#*=}" ;;
        --source-dir) shift; SOURCE_DIR="$1" ;;
        --force) FORCE=true ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$METHOD" in
    auto|pkg|source|path) ;;
    *) echo "Invalid --method: $METHOD (must be auto, pkg, source, or path)" >&2; exit 2 ;;
esac

if [ -z "$TOOLS_DIR" ]; then
    TOOLS_DIR="$(pwd)/build/tools"
fi
# Absolutize without requiring the directory to exist yet. The cd is checked:
# an empty TOOLS_DIR would silently turn TOOLS_BIN into "/bin" and aim the
# install at the system directory.
/bin/mkdir -p "$TOOLS_DIR" || exit 1
TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)" || exit 1
[ -n "$TOOLS_DIR" ] || { echo "Could not resolve --tools-dir" >&2; exit 1; }
TOOLS_BIN="$TOOLS_DIR/bin"

log() { echo "$@" >&2; }

# ---------------------------------------------------------------------------
# Version handling
# ---------------------------------------------------------------------------

# "replay 2.2" -> "2.2". Tolerates a leading "v" and trailing build metadata.
replay_version_of() {
    local bin="$1" out
    [ -x "$bin" ] || return 1
    out=$("$bin" --version 2>/dev/null) || return 1
    out=$(echo "$out" | /usr/bin/grep -oE '[0-9]+(\.[0-9]+)+' | /usr/bin/head -1)
    [ -n "$out" ] || return 1
    echo "$out"
}

# version_ge A B -> true when A >= B, comparing dotted numeric components.
# sort -V is not used: it would rank "2.10" below "2.2" only if fed unsorted
# input correctly, and a hand-rolled compare keeps the semantics obvious.
version_ge() {
    local a="$1" b="$2"
    local -a av bv
    IFS='.' read -r -a av <<< "$a"
    IFS='.' read -r -a bv <<< "$b"
    local i len=${#av[@]}
    [ ${#bv[@]} -gt $len ] && len=${#bv[@]}
    for (( i = 0; i < len; i++ )); do
        local x="${av[i]:-0}" y="${bv[i]:-0}"
        # Strip anything non-numeric so "2rc1" compares as 2.
        x=$(echo "$x" | /usr/bin/grep -oE '^[0-9]+' || echo 0)
        y=$(echo "$y" | /usr/bin/grep -oE '^[0-9]+' || echo 0)
        x=${x:-0}; y=${y:-0}
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

# Prints the path if the candidate exists and is new enough.
accept_if_good_enough() {
    local bin="$1" label="$2" version
    version=$(replay_version_of "$bin") || return 1
    if version_ge "$version" "$MIN_VERSION"; then
        log "  ${GREEN}Using replay ${version}${RESET} ($label): $bin"
        echo "$bin"
        return 0
    fi
    log "  Found replay $version at $bin ($label) - older than required $MIN_VERSION"
    return 1
}

# ---------------------------------------------------------------------------
# Discovery of an existing binary
# ---------------------------------------------------------------------------

find_existing_replay() {
    # An explicit override always wins, and is an error if it is unusable:
    # silently falling back would hide a typo in the caller's environment.
    if [ -n "${REPLAY_BIN:-}" ]; then
        if accept_if_good_enough "$REPLAY_BIN" "REPLAY_BIN override"; then
            return 0
        fi
        log "  ${RED}REPLAY_BIN is set to '$REPLAY_BIN' but it is unusable or too old${RESET}"
        return 1
    fi

    # A copy this script bootstrapped earlier.
    if [ -x "$TOOLS_BIN/replay" ]; then
        accept_if_good_enough "$TOOLS_BIN/replay" "previously bootstrapped" && return 0
    fi

    # A system-wide or user install.
    local on_path
    on_path=$(command -v replay 2>/dev/null)
    if [ -n "$on_path" ]; then
        accept_if_good_enough "$on_path" "on PATH" && return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Method: expand the release .pkg payload (no authorization required)
# ---------------------------------------------------------------------------

# Refuse a package macOS does not consider signed by a trusted authority.
# "pkgutil --check-signature" prints a certificate chain and exits 0 for a
# trusted signature, non-zero for an unsigned or broken one.
verify_pkg_signature() {
    local pkg="$1" output

    output=$(/usr/sbin/pkgutil --check-signature "$pkg" 2>&1)
    if [ $? -ne 0 ]; then
        log "  ${RED}Refusing the downloaded package: it is not signed by a trusted authority${RESET}"
        log "$(printf '%s\n' "$output" | /usr/bin/sed 's/^/    /')"
        log "  Use --replay-bootstrap=source to build replay from the git repository instead."
        return 1
    fi

    local signer
    signer=$(printf '%s\n' "$output" | /usr/bin/grep -m1 'Developer ID Installer' | /usr/bin/sed 's/^ *[0-9]*\. *//')
    if [ -n "$signer" ]; then
        log "  Signature OK: $signer"
    else
        log "  Signature OK"
    fi
    return 0
}

# A macOS product archive is a xar file holding one component .pkg per payload.
# Expanding it by hand installs nothing: no receipt, no root, no prompt.
extract_pkg_payload() {
    local pkg="$1" dest="$2"
    local work="$dest/xar"
    /bin/mkdir -p "$work" || return 1

    if ! ( cd "$work" && /usr/bin/xar -xf "$pkg" ) ; then
        log "  Could not expand the product archive with xar"
        return 1
    fi

    local payload payloads
    payloads=$(/usr/bin/find "$work" -name Payload -type f)
    if [ -z "$payloads" ]; then
        log "  No Payload found inside the package"
        return 1
    fi

    local unpacked="$dest/payload"
    /bin/mkdir -p "$unpacked" || return 1

    while IFS= read -r payload; do
        [ -z "$payload" ] && continue
        # Payload compression has varied across macOS releases: gzip+cpio is what
        # replay's package uses today, raw cpio and pbzx-then-tar are the others
        # worth trying before giving up.
        if /usr/bin/gunzip -c "$payload" 2>/dev/null | ( cd "$unpacked" && /usr/bin/cpio -i -d ) 2>/dev/null; then
            continue
        fi
        if ( cd "$unpacked" && /usr/bin/cpio -i -d ) < "$payload" 2>/dev/null; then
            continue
        fi
        if /usr/bin/tar -xf "$payload" -C "$unpacked" 2>/dev/null; then
            continue
        fi
        log "  Could not decode payload: $payload"
    done <<< "$payloads"

    local found
    found=$(/usr/bin/find "$unpacked" -type f -name replay | /usr/bin/head -1)
    if [ -z "$found" ]; then
        log "  Package payload did not contain a 'replay' binary"
        return 1
    fi

    echo "$found"
}

bootstrap_from_pkg() {
    log "  Looking up the latest replay release..."

    local url=""
    local api_json
    api_json=$(/usr/bin/curl -sL --fail --max-time 30 "$RELEASES_API" 2>/dev/null || echo "")
    if [ -n "$api_json" ]; then
        # Anchored to the release-asset path rather than matching any ".pkg"
        # URL in the response, so a field that happens to precede "assets" and
        # happens to contain such a URL cannot win the head -1.
        url=$(echo "$api_json" \
            | /usr/bin/grep -oE "https://[^\"]*/${RELEASE_ASSET_PATH}/[^\"]*\.pkg" \
            | /usr/bin/head -1)
    fi

    # The API is rate-limited per source address; scraping the releases page is
    # the fallback that keeps an unauthenticated machine working.
    if [ -z "$url" ]; then
        log "  Release API unavailable - scraping the releases page"
        local page
        page=$(/usr/bin/curl -sL --fail --max-time 30 "$RELEASES_PAGE" 2>/dev/null || echo "")
        local rel
        rel=$(echo "$page" | /usr/bin/grep -oE "/${RELEASE_ASSET_PATH}/[^\"]*\.pkg" | /usr/bin/head -1)
        [ -n "$rel" ] && url="https://github.com${rel}"
    fi

    if [ -z "$url" ]; then
        log "  ${RED}Could not determine a release package URL${RESET}"
        return 1
    fi

    log "  Downloading ${url##*/}"

    local tmp
    tmp=$(/usr/bin/mktemp -d -t replay-bootstrap) || return 1

    local pkg="$tmp/${url##*/}"
    if ! /usr/bin/curl -fsSL --max-time 300 -o "$pkg" "$url"; then
        log "  ${RED}Download failed${RESET}"
        /bin/rm -rf "$tmp"
        return 1
    fi

    # Expanding the payload by hand bypasses the signature check the installer
    # would have performed, so perform it here instead. A package that is signed
    # by a trusted authority is the only thing this can establish - the release
    # publishes no checksum to pin against - but an unsigned or tampered package
    # is worth refusing outright rather than executing.
    verify_pkg_signature "$pkg" || { /bin/rm -rf "$tmp"; return 1; }

    log "  Expanding the package payload (nothing is installed system-wide)"
    local binary
    binary=$(extract_pkg_payload "$pkg" "$tmp")
    if [ -z "$binary" ]; then
        /bin/rm -rf "$tmp"
        return 1
    fi

    /bin/mkdir -p "$TOOLS_BIN" || { /bin/rm -rf "$tmp"; return 1; }
    /bin/cp -f "$binary" "$TOOLS_BIN/replay" || { /bin/rm -rf "$tmp"; return 1; }
    /bin/chmod +x "$TOOLS_BIN/replay"

    local payload_dir="${binary%/replay}"
    local tool
    for tool in "${SIBLING_TOOLS[@]}"; do
        if [ -f "$payload_dir/$tool" ]; then
            /bin/cp -f "$payload_dir/$tool" "$TOOLS_BIN/$tool" && /bin/chmod +x "$TOOLS_BIN/$tool"
        fi
    done

    # A curl download carries no quarantine attribute, but a package that
    # reached the machine another way might; clear it rather than fail later.
    /usr/bin/xattr -d com.apple.quarantine "$TOOLS_BIN/replay" 2>/dev/null

    /bin/rm -rf "$tmp"

    accept_if_good_enough "$TOOLS_BIN/replay" "expanded from release package"
}

# ---------------------------------------------------------------------------
# Method: build from source
# ---------------------------------------------------------------------------

# Deliberately not the upstream "source <(curl ...) install.sh" one-liner: that
# installs into ~/.local/bin and appends a PATH line to ~/.zshrc. A build script
# should not edit the user's shell configuration behind their back. The same
# swift build runs here, and the products land in the build tree.
bootstrap_from_source() {
    if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
        log "  ${RED}Xcode command line tools are required to build from source${RESET}"
        log "  Install them with: xcode-select --install"
        return 1
    fi
    if ! command -v swift >/dev/null 2>&1; then
        log "  ${RED}'swift' not found - cannot build from source${RESET}"
        return 1
    fi

    local tmp="" build_root=""

    if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
        log "  Building from existing checkout: $SOURCE_DIR"
        build_root="$SOURCE_DIR"
    else
        tmp=$(/usr/bin/mktemp -d -t replay-source) || return 1
        log "  Cloning $SOURCE_REPO"
        if ! /usr/bin/git clone --depth 1 "$SOURCE_REPO" "$tmp/replay" >&2; then
            log "  ${RED}Clone failed${RESET}"
            /bin/rm -rf "$tmp"
            return 1
        fi
        build_root="$tmp/replay"
    fi

    log "  swift build -c release (this takes a few minutes the first time)"
    if ! ( cd "$build_root" && swift build -c release >&2 ); then
        log "  ${RED}Build failed${RESET}"
        [ -n "$tmp" ] && /bin/rm -rf "$tmp"
        return 1
    fi

    local products="$build_root/.build/release"
    if [ ! -x "$products/replay" ]; then
        log "  ${RED}Build produced no replay binary in $products${RESET}"
        [ -n "$tmp" ] && /bin/rm -rf "$tmp"
        return 1
    fi

    /bin/mkdir -p "$TOOLS_BIN" || { [ -n "$tmp" ] && /bin/rm -rf "$tmp"; return 1; }
    /usr/bin/install "$products/replay" "$TOOLS_BIN/" >&2
    local tool
    for tool in "${SIBLING_TOOLS[@]}"; do
        [ -x "$products/$tool" ] && /usr/bin/install "$products/$tool" "$TOOLS_BIN/" >&2
    done

    [ -n "$tmp" ] && /bin/rm -rf "$tmp"

    accept_if_good_enough "$TOOLS_BIN/replay" "built from source"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "==== Locating replay (>= $MIN_VERSION) ===="

if ! $FORCE; then
    if resolved=$(find_existing_replay); then
        echo "$resolved"
        exit 0
    fi
fi

if [ "$METHOD" = "path" ]; then
    log "  ${RED}No replay >= $MIN_VERSION found and --method=path forbids installing one${RESET}"
    exit 1
fi

if [ "$METHOD" = "auto" ] || [ "$METHOD" = "pkg" ]; then
    log "  Bootstrapping replay from the latest release package"
    if resolved=$(bootstrap_from_pkg); then
        echo "$resolved"
        exit 0
    fi
    if [ "$METHOD" = "pkg" ]; then
        log "  ${RED}Package bootstrap failed${RESET}"
        exit 1
    fi
    log "  Package bootstrap failed - falling back to building from source"
fi

if resolved=$(bootstrap_from_source); then
    echo "$resolved"
    exit 0
fi

log "  ${RED}Could not obtain a usable replay >= $MIN_VERSION${RESET}"
log "  You can install it manually with:"
log "    source <(/usr/bin/curl -fsSL 'https://raw.githubusercontent.com/abra-code/replay/refs/heads/master/install.sh')"
log "  then re-run this build."
exit 1
