#!/bin/bash
# build-embedded-python.sh
# Builds a minimal, relocatable deployment-only Python for macOS embedding.

set -uo pipefail

RED=$(printf '\033[91m')
GREEN=$(printf '\033[92m')
RESET=$(printf '\033[0m')

VERSION="auto"
ARCH="universal"
OPENSSL_VERSION="auto"
XZ_VERSION="none"
FINAL_DIR=""

# --- replay build engine (alternative, non-default) -------------------------
USE_REPLAY=false          # --use-replay selects the playlist-driven build
REPLAY_CACHE=true         # --replay-no-cache turns off incremental execution
REPLAY_CACHE_REFRESH=false
REPLAY_DRY_RUN=false
REPLAY_SERIAL=false
REPLAY_VERBOSE=false
REPLAY_MAX_TASKS=""
REPLAY_BOOTSTRAP_METHOD="auto"
REPLAY_MIN_VERSION="2.2"  # the release that introduced the execution cache
TASK=""                   # internal: run a single named build step and exit
START_DIR_OVERRIDE=""     # internal: anchor paths independently of the cwd

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --version=VERSION   Python version to build (default: auto-detect latest stable)
  --arch=ARCH         Architecture: universal, arm64, or x86_64 (default: universal)
                      Note: cross-compilation, e.g. building x86_64 on Apple Silicon Macs
                            is not supported by Python build system. Build universal instead
  --openssl-version=VERSION   OpenSSL version (default: auto-detect latest stable)
  --lzma-version=VERSION      Build and statically link liblzma (xz-utils) at given version.
                              Use "auto" to auto-detect, or a specific version like "5.6.4".
                              Omit this flag to skip lzma (default: not built)
  --output=path/to/final/dir  Optional path to final directory to place built products
  --help              Show this help message

Replay build engine (optional, off by default):
  --use-replay        Build through a generated "replay" playlist instead of the
                      hardcoded sequence. Downloads and dependency builds that do
                      not depend on each other run concurrently, and every step
                      is skipped on later runs while its declared inputs and
                      outputs are unchanged. "replay" >= ${REPLAY_MIN_VERSION} is
                      installed into build/tools automatically if missing.
  --replay-no-cache   Use replay for scheduling only, without incremental skipping
  --replay-cache-refresh   Re-execute every step and rebuild the cache manifest.
                      Use this after editing the playlist structure.
  --replay-dry-run    Print the execution plan, and with the cache the per-step
                      HIT/MISS report, without building anything
  --replay-serial     Run playlist steps one at a time in playlist order
  --replay-verbose    Show each step and its cache decision as it is scheduled
  --replay-jobs=N     Cap concurrently running steps (default: unbound)
  --replay-bootstrap=METHOD   How to obtain replay: auto (default), pkg, source, path
                      pkg expands the release package payload without an authorization
                      prompt; source builds it with swift; path refuses to install.

Example:
  ./build-embedded-python.sh --version=3.13.0 --arch=arm64
  ./build-embedded-python.sh --version=auto --arch=universal
  ./build-embedded-python.sh --version=auto --lzma-version=auto
  ./build-embedded-python.sh --use-replay --lzma-version=auto
  ./build-embedded-python.sh --use-replay --replay-dry-run   # what would rebuild?
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) show_help ;;
        --version=*) VERSION="${1#*=}" ;;
        --version) shift; VERSION="$1" ;;
        --arch=*) ARCH="${1#*=}" ;;
        --arch) shift; ARCH="$1" ;;
        --openssl-version=*) OPENSSL_VERSION="${1#*=}" ;;
        --openssl-version) shift; OPENSSL_VERSION="$1" ;;
        --lzma-version=*) XZ_VERSION="${1#*=}" ;;
        --lzma-version) shift; XZ_VERSION="$1" ;;
        --output=*) FINAL_DIR="${1#*=}" ;;
        --output) shift; FINAL_DIR="$1" ;;

        --use-replay) USE_REPLAY=true ;;
        --replay-no-cache) REPLAY_CACHE=false ;;
        --replay-cache-refresh) REPLAY_CACHE_REFRESH=true ;;
        --replay-dry-run) REPLAY_DRY_RUN=true ;;
        --replay-serial) REPLAY_SERIAL=true ;;
        --replay-verbose) REPLAY_VERBOSE=true ;;
        --replay-jobs=*) REPLAY_MAX_TASKS="${1#*=}" ;;
        --replay-jobs) shift; REPLAY_MAX_TASKS="$1" ;;
        --replay-bootstrap=*) REPLAY_BOOTSTRAP_METHOD="${1#*=}" ;;
        --replay-bootstrap) shift; REPLAY_BOOTSTRAP_METHOD="$1" ;;

        # Internal: one playlist step re-invokes this script for a single build
        # phase. Not advertised in --help; the playlist is the only caller.
        --task=*) TASK="${1#*=}" ;;
        --task) shift; TASK="$1" ;;
        --start-dir=*) START_DIR_OVERRIDE="${1#*=}" ;;
        --start-dir) shift; START_DIR_OVERRIDE="$1" ;;

        *) echo "Unknown option: $1"; show_help ;;
    esac
    shift
done

# Normalize FINAL_DIR to absolute path right after parsing
if [ -n "$FINAL_DIR" ]; then
    FINAL_DIR_PARENT="$(cd "$(dirname -- "$FINAL_DIR")" 2>/dev/null && pwd)"
    # Without this check a nonexistent parent silently collapsed the output path
    # to "/<basename>", which is both wrong and rooted at a directory the build
    # later deletes and recreates.
    if [ -z "$FINAL_DIR_PARENT" ]; then
        echo "${RED}FATAL: parent directory of --output does not exist: $(dirname -- "$FINAL_DIR")${RESET}" >&2
        exit 1
    fi
    FINAL_DIR="${FINAL_DIR_PARENT}/$(basename -- "$FINAL_DIR")"
    FINAL_DIR="${FINAL_DIR%/}"   # remove trailing slash if any
fi

MACOSX_DEPLOYMENT_TARGET="11.0"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"  # absolute path to script dir
SCRIPT_PATH="$SCRIPT_DIR/$(/usr/bin/basename "$0")"  # absolute path to this script

# Invocation directory. Playlist steps run as separate processes with no control
# over their working directory, so they are handed the anchor explicitly and
# every path below stays identical to the one the sequential build computes.
if [ -n "$START_DIR_OVERRIDE" ]; then
    START_DIR="$START_DIR_OVERRIDE"
else
    START_DIR="$(pwd)"
fi

# this env var prevents creating .pyc precompiled files in the installation location
export PYTHONPYCACHEPREFIX='/tmp/Pyc'

# Abort the current process with a message. In the sequential build this stops
# the run; in a playlist step it fails that step, which replay reports and,
# importantly, does not record as a cache entry.
fail() {
    echo "  ${RED}FATAL: $*${RESET}" >&2
    exit 1
}

# Run a command and abort if it fails. Used for the steps whose failure must not
# be papered over - configure, make, downloads, unpacking, the final copy.
run_checked() {
    "$@" || fail "command failed (exit $?): $*"
}

detect_latest_python() {
    echo "Detecting latest stable Python version..."
        
    # Strategy 1: Try GitHub tags API
    echo "  Trying GitHub API for cpython tags..."
    local tags_json
    tags_json=$(/usr/bin/curl -s --fail --max-time 10 "https://api.github.com/repos/python/cpython/tags?per_page=20" 2>/dev/null || echo "")
    
    if [ -n "$tags_json" ]; then
        # Extract stable version tags (v3.x.y format, excluding alpha/beta/rc)
        local latest_tag
        latest_tag=$(echo "$tags_json" | \
            /usr/bin/grep -oE '"name":\s*"v3\.[0-9]+\.[0-9]+"' | \
            /usr/bin/grep -oE '3\.[0-9]+\.[0-9]+' | \
            /usr/bin/sort -V | \
            /usr/bin/tail -1)
        
        if [[ "$latest_tag" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
            VERSION="$latest_tag"
            echo "  Detected from GitHub tags: $VERSION"
            return 0
        fi
    fi
    
    # Strategy 2: Scrape GitHub tags page as fallback
    echo "  Trying GitHub tags page scraping..."
    local tags_page
    tags_page=$(/usr/bin/curl -s --fail --max-time 10 "https://github.com/python/cpython/tags" 2>/dev/null || echo "")
    
    if [ -n "$tags_page" ]; then
        local latest_tag
        latest_tag=$(echo "$tags_page" | \
            /usr/bin/grep -oE 'href="/python/cpython/releases/tag/v3\.[0-9]+\.[0-9]+"' | \
            /usr/bin/grep -oE '3\.[0-9]+\.[0-9]+' | \
            /usr/bin/sort -V | \
            /usr/bin/tail -1)
        
        if [[ "$latest_tag" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
            VERSION="$latest_tag"
            echo "  Detected from GitHub page: $VERSION"
            return 0
        fi
    fi

    # Strategy 3: Parse python.org/downloads/source/
    # This does not seem to work. curl return status 56 and the result is empty
    echo "  Trying python.org downloads page..."
    local downloads_page
    downloads_page=$(/usr/bin/curl -s --fail --max-time 10 \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        "https://www.python.org/downloads/source/" 2>/dev/null || echo "")
    
    if [[ "$downloads_page" =~ Latest\ Python\ 3\ Release\ -\ Python\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        VERSION="${BASH_REMATCH[1]}"
        echo "  Detected from python.org: $VERSION"
        return 0
    fi

    # All strategies failed
    VERSION="3.14.2"
    echo "  ${RED}Detection failed — falling back to $VERSION${RESET}"
    echo "  You can specify a version explicitly with --version=X.Y.Z"
}

validate_arch() {
    case "$ARCH" in
        universal|arm64|x86_64) ;;
        *) echo "Invalid ARCH: $ARCH (must be universal, arm64, or x86_64)"; exit 1 ;;
    esac
}

# Derive every build path from the resolved version and architecture. Pure and
# silent: the sequential build and each playlist step both call it and must
# arrive at exactly the same paths, so nothing here may depend on the cwd, on
# network detection, or on what a previous phase happened to leave behind.
compute_paths() {
    MAJOR_MINOR=$(echo "$VERSION" | cut -d. -f1-2)

    # Build directory structure
    BUILD_ROOT="${START_DIR}/build"
    DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
    BUILD_FLAVOR_DIR="${BUILD_ROOT}/python-${VERSION}-${ARCH}"
    PYTHON_SRC="${BUILD_FLAVOR_DIR}/src"
    OPENSSL_SRC="${BUILD_FLAVOR_DIR}/openssl-src"
    OPENSSL_BUILD="${BUILD_FLAVOR_DIR}/openssl-build"
    OPENSSL_INSTALL="${BUILD_FLAVOR_DIR}/openssl-install"
    XZ_SRC="${BUILD_FLAVOR_DIR}/xz-src"
    XZ_BUILD="${BUILD_FLAVOR_DIR}/xz-build"
    XZ_INSTALL="${BUILD_FLAVOR_DIR}/xz-install"
    INSTALL_DIR="${BUILD_FLAVOR_DIR}/install"
    STAMP_DIR="${BUILD_FLAVOR_DIR}/stamps"
    if [ -z "$FINAL_DIR" ]; then
        FINAL_DIR="${START_DIR}/Python-${VERSION}-${ARCH}"
    fi
}

prepare() {
    echo
    echo "==== Starting build ===="
    echo

    validate_arch

    # Auto-detect Python version if needed
    if [[ "$VERSION" == "auto" ]]; then
        detect_latest_python
    fi

    compute_paths

    /bin/mkdir -pv "${PYTHONPYCACHEPREFIX}"
    /bin/mkdir -pv "${DOWNLOAD_DIR}"

    echo
    echo "Python version : $VERSION"
    echo "Target architecture : $ARCH"
    echo "Build root     : $BUILD_ROOT"
    echo "Downloads      : $DOWNLOAD_DIR"
    echo "Build flavor dir : $BUILD_FLAVOR_DIR"
    echo "Final output   : $FINAL_DIR"
    echo

}

# The download of each dependency is split from its unpacking so that a playlist
# can schedule the three downloads concurrently against the builds, and cache
# each half on its own. The sequential build calls the two in a row and behaves
# exactly as the single function did.

# Download to a scratch name and rename only after the transfer succeeded.
# curl leaves a partial file behind when a connection drops mid-transfer (a
# clean 404 it removes, a dropped socket it does not), and every fetch here
# treats "the tarball is already there" as "nothing to do". Without the rename
# an interrupted download becomes a truncated tarball that the next run accepts
# and the cache then records as a satisfied output, so the unpack fails on every
# subsequent run until someone deletes the stub by hand.
download_to() {
    local url="$1" dest="$2"
    shift 2
    local partial="${dest}.partial"

    /bin/rm -f "$partial"
    if ! /usr/bin/curl -L --fail --show-error "$@" -o "$partial" "$url"; then
        /bin/rm -f "$partial"
        return 1
    fi
    /bin/mv -f "$partial" "$dest" || return 1
}

python_tarball_path() { echo "$DOWNLOAD_DIR/Python-${VERSION}.tar.xz"; }

fetch_python() {
    echo
    echo "==== Downloading Python source ===="
    echo

    /bin/mkdir -pv "$DOWNLOAD_DIR"
    local tarball; tarball=$(python_tarball_path)
    local url="https://www.python.org/ftp/python/${VERSION}/Python-${VERSION}.tar.xz"

    if [ ! -f "$tarball" ]; then
        echo "  Fetching $url"
        download_to "$url" "$tarball" || fail "could not download $url"
    else
        echo "  Python tarball already in downloads"
    fi
}

unpack_python() {
    echo
    echo "==== Unpacking Python source ===="
    echo

    local tarball; tarball=$(python_tarball_path)
    [ -f "$tarball" ] || fail "Python tarball not found: $tarball"

    /bin/mkdir -pv "$PYTHON_SRC"
    echo "  Unpacking to $PYTHON_SRC"
    run_checked /usr/bin/tar -xf "$tarball" -C "$PYTHON_SRC" --strip-components=1
}

download_python() {
    fetch_python
    unpack_python
}

detect_latest_openssl() {
    echo "Detecting latest stable OpenSSL version"

    local latest_url
    latest_url=$(/usr/bin/curl -s --head -w '%{redirect_url}' https://github.com/openssl/openssl/releases/latest 2>/dev/null || echo "")

    if [[ "$latest_url" =~ /tag/openssl-([^/]+)$ ]]; then
        OPENSSL_VERSION="${BASH_REMATCH[1]}"
        echo "  Detected: $OPENSSL_VERSION"
    else
        OPENSSL_VERSION="3.6.0"
        echo "  Detection failed - falling back to $OPENSSL_VERSION"
    fi
    echo
}

detect_latest_openssl_36x() {
    echo "  Detecting latest stable OpenSSL 3.6.x version..."
    local releases_json
    releases_json=$(/usr/bin/curl -s --fail --max-time 10 \
        "https://api.github.com/repos/openssl/openssl/releases?per_page=50" 2>/dev/null || echo "")

    if [ -n "$releases_json" ]; then
        local latest_36x
        latest_36x=$(echo "$releases_json" | \
            /usr/bin/grep -oE '"tag_name":\s*"openssl-3\.6\.[0-9]+"' | \
            /usr/bin/grep -oE '3\.6\.[0-9]+' | \
            /usr/bin/sort -V | \
            /usr/bin/tail -1)

        if [[ "$latest_36x" =~ ^3\.6\.[0-9]+$ ]]; then
            OPENSSL_VERSION="$latest_36x"
            echo "  Detected: $OPENSSL_VERSION"
            return 0
        fi
    fi

    OPENSSL_VERSION="3.6.2"
    echo "  ${RED}Detection failed — falling back to $OPENSSL_VERSION${RESET}"
}

# Python 3.14.x and earlier are incompatible with OpenSSL 4.x (fixed in Python 3.15+).
# If a forbidden combination is detected, cap OpenSSL to the latest 3.6.x series.
enforce_openssl_version_constraint() {
    local python_minor openssl_major
    python_minor=$(echo "$MAJOR_MINOR" | cut -d. -f2)
    openssl_major=$(echo "$OPENSSL_VERSION" | cut -d. -f1)

    if [ "$python_minor" -lt 15 ] && [ "$openssl_major" -ge 4 ]; then
        echo "  ${RED}WARNING: OpenSSL ${OPENSSL_VERSION} is not compatible with Python ${VERSION}.${RESET}"
        echo "  Python < 3.15 requires OpenSSL 3.x (OpenSSL 4.x support is expected in Python 3.15+)."
        echo "  Capping OpenSSL to the latest 3.6.x series..."
        detect_latest_openssl_36x
        echo
    fi
}


openssl_tarball_path() { echo "$DOWNLOAD_DIR/openssl-${OPENSSL_VERSION}.tar.gz"; }

fetch_openssl() {
    echo
    echo "==== Downloading OpenSSL ===="
    echo

    local tarball; tarball=$(openssl_tarball_path)
    local url="https://www.openssl.org/source/${tarball##*/}"
    local github_url="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${tarball##*/}"
    local checksum_url="${url}.sha256"

    echo "Downloading OpenSSL source (${OPENSSL_VERSION})..."
    /bin/mkdir -pv "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR" || fail "cannot enter $DOWNLOAD_DIR"

    if [ -f "$tarball" ]; then
        echo "  OpenSSL tarball already present in downloads"
    else
        local curl_official=false
        download_to "$url" "$tarball" --silent && curl_official=true

        if $curl_official; then
            echo "  Downloaded from official openssl.org"
        else
            echo "  Official URL failed - falling back to GitHub"
            download_to "$github_url" "$tarball" || fail "could not download $github_url"
        fi

        local checksum_downloaded=false
        /usr/bin/curl -L --silent --fail -o "${tarball}.sha256" "$checksum_url" && checksum_downloaded=true

        if $checksum_downloaded; then
            echo "  Verifying SHA256 checksum..."
            local checksum_ok=false
            /usr/bin/shasum --algorithm 256 --check "${tarball}.sha256" && checksum_ok=true
            /bin/rm -f "${tarball}.sha256"

            if $checksum_ok; then
                echo "  Checksum verified."
            else
                # Leaving it on disk would be worse than not downloading it at
                # all: the next run takes the "already present" branch above,
                # which skips verification entirely, so a tarball that failed
                # its checksum would be built without ever being checked again.
                echo "  ${RED}Checksum verification FAILED - discarding tarball${RESET}"
                /bin/rm -f "$tarball"
                exit 1
            fi
        else
            echo "  No checksum file available - skipping verification"
        fi
    fi
}

unpack_openssl() {
    echo
    echo "==== Unpacking OpenSSL source ===="
    echo

    local tarball; tarball=$(openssl_tarball_path)
    [ -f "$tarball" ] || fail "OpenSSL tarball not found: $tarball"

    # Unpack into flavor-specific openssl-src (next to openssl-build)
    /bin/rm -rf "$OPENSSL_SRC"
    /bin/mkdir -pv "$OPENSSL_SRC"
    run_checked /usr/bin/tar xf "$tarball" -C "$OPENSSL_SRC" --strip-components=1
}

download_openssl() {
    if [[ "$OPENSSL_VERSION" == "auto" ]]; then
        detect_latest_openssl
    fi

    enforce_openssl_version_constraint

    fetch_openssl
    unpack_openssl
}

build_openssl() {
    echo
    echo "==== Building OpenSSL ${OPENSSL_VERSION} as shared libs ===="
    echo

    export MACOSX_DEPLOYMENT_TARGET

    cd "$BUILD_FLAVOR_DIR" || fail "cannot enter $BUILD_FLAVOR_DIR"
    /bin/rm -rf "$OPENSSL_BUILD" "$OPENSSL_INSTALL"
    /bin/mkdir -pv "$OPENSSL_BUILD" "$OPENSSL_INSTALL"

    local target_archs=()
    if [ "$ARCH" = "universal" ]; then
        target_archs=("x86_64" "arm64")
    elif [ "$ARCH" = "arm64" ]; then
        target_archs=("arm64")
    else
        target_archs=("x86_64")
    fi

    local per_arch_installs=()
    local host_arch
    for host_arch in "${target_archs[@]}"; do
        local arch_build="${OPENSSL_BUILD}/${host_arch}"
        local arch_install="${OPENSSL_BUILD}/${host_arch}-install"
        /bin/mkdir -pv "$arch_build" "$arch_install"
        per_arch_installs+=("$arch_install")

        cd "$arch_build" || fail "cannot enter $arch_build"

        local config_target
        if [ "$host_arch" = "arm64" ]; then
            config_target="darwin64-arm64-cc"
        else
            config_target="darwin64-x86_64-cc"
        fi

        echo "Configuring OpenSSL for $host_arch (shared)..."
        run_checked "$OPENSSL_SRC/Configure" $config_target shared no-asm \
            --prefix="$arch_install" --openssldir="$arch_install/ssl"

        run_checked /usr/bin/make -j8
        run_checked /usr/bin/make install_sw install_ssldirs
        cd "$BUILD_FLAVOR_DIR" || fail "cannot enter $BUILD_FLAVOR_DIR"
    done

    /bin/cp -R "${per_arch_installs[0]}/"* "$OPENSSL_INSTALL/"

    if [ "$ARCH" = "universal" ]; then
        echo "Creating universal dylibs via lipo..."
        run_checked /usr/bin/lipo -create \
            "${per_arch_installs[0]}/lib/libssl.dylib" \
            "${per_arch_installs[1]}/lib/libssl.dylib" \
            -output "$OPENSSL_INSTALL/lib/libssl.dylib"

        run_checked /usr/bin/lipo -create \
            "${per_arch_installs[0]}/lib/libcrypto.dylib" \
            "${per_arch_installs[1]}/lib/libcrypto.dylib" \
            -output "$OPENSSL_INSTALL/lib/libcrypto.dylib"
    fi
}

detect_latest_xz() {
    echo "Detecting latest stable xz version..."

    local latest_url
    latest_url=$(/usr/bin/curl -s --head -w '%{redirect_url}' https://github.com/tukaani-project/xz/releases/latest 2>/dev/null || echo "")

    if [[ "$latest_url" =~ /tag/v([^/]+)$ ]]; then
        XZ_VERSION="${BASH_REMATCH[1]}"
        echo "  Detected: $XZ_VERSION"
    else
        XZ_VERSION="5.8.3"
        echo "  ${RED}Detection failed — falling back to $XZ_VERSION${RESET}"
    fi
    echo
}

xz_tarball_path() { echo "$DOWNLOAD_DIR/xz-${XZ_VERSION}.tar.gz"; }

fetch_xz() {
    [ "$XZ_VERSION" = "none" ] && return 0

    echo
    echo "==== Downloading xz-utils ===="
    echo

    local tarball; tarball=$(xz_tarball_path)
    local url="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"

    echo "Downloading xz-utils source (${XZ_VERSION})..."
    /bin/mkdir -pv "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR" || fail "cannot enter $DOWNLOAD_DIR"

    if [ -f "$tarball" ]; then
        echo "  xz tarball already present in downloads"
    else
        download_to "$url" "$tarball" || fail "could not download $url"
    fi
}

unpack_xz() {
    [ "$XZ_VERSION" = "none" ] && return 0

    echo
    echo "==== Unpacking xz-utils source ===="
    echo

    local tarball; tarball=$(xz_tarball_path)
    [ -f "$tarball" ] || fail "xz tarball not found: $tarball"

    /bin/rm -rf "$XZ_SRC"
    /bin/mkdir -pv "$XZ_SRC"
    run_checked /usr/bin/tar xf "$tarball" -C "$XZ_SRC" --strip-components=1
}

download_xz() {
    [ "$XZ_VERSION" = "none" ] && return 0

    if [[ "$XZ_VERSION" == "auto" ]]; then
        detect_latest_xz
    fi

    fetch_xz
    unpack_xz
}

build_xz() {
    [ "$XZ_VERSION" = "none" ] && return 0

    echo
    echo "==== Building xz-utils ${XZ_VERSION} as static library ===="
    echo

    export MACOSX_DEPLOYMENT_TARGET

    cd "$BUILD_FLAVOR_DIR" || fail "cannot enter $BUILD_FLAVOR_DIR"
    /bin/rm -rf "$XZ_BUILD" "$XZ_INSTALL"
    /bin/mkdir -pv "$XZ_BUILD" "$XZ_INSTALL"

    local target_archs=()
    if [ "$ARCH" = "universal" ]; then
        target_archs=("x86_64" "arm64")
    elif [ "$ARCH" = "arm64" ]; then
        target_archs=("arm64")
    else
        target_archs=("x86_64")
    fi

    local per_arch_installs=()
    local host_arch
    for host_arch in "${target_archs[@]}"; do
        local arch_build="${XZ_BUILD}/${host_arch}"
        local arch_install="${XZ_BUILD}/${host_arch}-install"
        /bin/mkdir -pv "$arch_build" "$arch_install"
        per_arch_installs+=("$arch_install")

        cd "$arch_build" || fail "cannot enter $arch_build"

        echo "Configuring xz for $host_arch (static only)..."
        CC="/usr/bin/clang -arch $host_arch" \
        run_checked "$XZ_SRC/configure" \
            --prefix="$arch_install" \
            --disable-shared \
            --enable-static \
            --with-pic \
            --disable-xz \
            --disable-xzdec \
            --disable-lzmadec \
            --disable-lzmainfo \
            --disable-scripts \
            --disable-doc \
            --host="$host_arch-apple-darwin"

        /usr/bin/make -j8
        /usr/bin/make install
        cd "$BUILD_FLAVOR_DIR" || fail "cannot enter $BUILD_FLAVOR_DIR"
    done

    # Copy first arch install as base
    /bin/cp -R "${per_arch_installs[0]}/"* "$XZ_INSTALL/"

    if [ "$ARCH" = "universal" ]; then
        echo "Creating universal static library via lipo..."
        /usr/bin/lipo -create \
            "${per_arch_installs[0]}/lib/liblzma.a" \
            "${per_arch_installs[1]}/lib/liblzma.a" \
            -output "$XZ_INSTALL/lib/liblzma.a"
    fi

    echo "  Static liblzma built at: $XZ_INSTALL/lib/liblzma.a"
    /usr/bin/file "$XZ_INSTALL/lib/liblzma.a"
}

setup_lzma_module() {
    [ "$XZ_VERSION" = "none" ] && return 0

    echo
    echo "==== Configuring _lzma module for static liblzma linkage ===="
    echo

    local setup_local="$PYTHON_SRC/Modules/Setup.local"

    # Drop any block a previous run of this function left behind before writing a
    # fresh one. Appending blindly duplicated the module definition whenever the
    # step ran twice against a source tree that was not re-unpacked, which is the
    # normal case under the replay cache: a step may re-execute while the tree
    # it edits survives from the run before.
    if [ -f "$setup_local" ]; then
        local filtered="${setup_local}.tmp"
        /usr/bin/grep -v -E '^\*shared\*$|^_lzma _lzmamodule\.c ' "$setup_local" > "$filtered"
        /bin/mv "$filtered" "$setup_local"
    fi

    # *shared* marker makes the module build as a .so in lib-dynload/ rather than
    # being compiled statically into libpython. The liblzma.a is still linked
    # statically into _lzma.so itself, so there is no dynamic liblzma dependency.
    # The redirect has to be checked: unchecked, this function returned the exit
    # status of the trailing "cat", so a write that failed (missing or read-only
    # Modules/) still reported success. Under the cache that is recorded as a
    # satisfied step, and Python is then configured without _lzma for good.
    printf '*shared*\n_lzma _lzmamodule.c -I%s/include %s/lib/liblzma.a\n' \
        "$XZ_INSTALL" "$XZ_INSTALL" >> "$setup_local" \
        || fail "could not write $setup_local"
    echo "  Written to $setup_local:"
    /bin/cat "$setup_local"
}

copy_and_relocate_openssl_dylibs() {
    echo
    echo "==== Copying and relocating bundled OpenSSL shared libraries ===="
    echo

    /bin/mkdir -pv "$INSTALL_DIR/lib"
    echo "  Copying libssl.dylib and libcrypto.dylib"
    run_checked /bin/cp -v "$OPENSSL_INSTALL/lib/libssl.dylib" "$OPENSSL_INSTALL/lib/libcrypto.dylib" "$INSTALL_DIR/lib/"

    cd "$INSTALL_DIR/lib" || fail "cannot enter $INSTALL_DIR/lib"
    echo "  Stripping debug symbols from dylibs"
    /usr/bin/strip -x -v libssl.dylib libcrypto.dylib

    # An install name that did not get rewritten is the difference between a
    # relocatable distribution and one that only works on this machine, so these
    # are fatal rather than best-effort.
    echo "  Setting relative install names"
    run_checked /usr/bin/install_name_tool -id "@executable_path/../lib/libssl.dylib" libssl.dylib
    run_checked /usr/bin/install_name_tool -id "@executable_path/../lib/libcrypto.dylib" libcrypto.dylib

    echo "  Fixing all libcrypto references in libssl.dylib"
    local crypto_refs
    crypto_refs=$( /usr/bin/otool -L libssl.dylib | /usr/bin/awk '/libcrypto/ {print $1}' )
    
    if [ -n "$crypto_refs" ]; then
        local crypto_ref
        while IFS= read -r crypto_ref; do
            [ -z "$crypto_ref" ] && continue
            echo "    Changing: $crypto_ref -> @executable_path/../lib/libcrypto.dylib"
            /usr/bin/install_name_tool -change "$crypto_ref" "@executable_path/../lib/libcrypto.dylib" libssl.dylib
        done <<< "$crypto_refs"
    fi
}

configure_python() {
    echo
    echo "==== Configuring Python ===="
    echo

    cd "$PYTHON_SRC" || fail "cannot enter $PYTHON_SRC"
    /bin/mkdir -pv "$INSTALL_DIR"
    
    # Clean any previous build artifacts that might have wrong architecture
    echo "  Cleaning previous build artifacts..."
    /usr/bin/make distclean 2>/dev/null

    # CPython's distclean target deletes Modules/Setup.local along with the
    # generated makefiles, so the _lzma definition written earlier is gone by
    # now and has to be re-asserted before ./configure looks at it. On a freshly
    # unpacked tree distclean finds no Makefile and does nothing, which is why
    # the sequential build never noticed; re-running against an existing tree
    # would have silently dropped the module.
    setup_lzma_module

    local -a flags=(
        --enable-shared
        --enable-optimizations
        --with-lto
        --prefix="$INSTALL_DIR"
        --with-openssl="$OPENSSL_INSTALL"
        --with-openssl-rpath=auto
        --disable-tkinter
    )

    flags+=(MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET})

    if [ "$XZ_VERSION" != "none" ]; then
        # Point Python's configure at the static liblzma headers/lib so it can
        # find lzma.h. Since only liblzma.a exists (--disable-shared), the linker
        # will always pick the static archive.
        flags+=(CPPFLAGS="-I${XZ_INSTALL}/include")
        flags+=(LDFLAGS="-L${XZ_INSTALL}/lib")
    fi

    if [ "$ARCH" = "universal" ]; then
        flags+=(--enable-universalsdk --with-universal-archs=universal2)
        echo "Configuring Python for universal2"
    else
        
        # Detect the build machine architecture
        local build_arch
        build_arch=$(/usr/bin/uname -m)
        
        if [ "$build_arch" != "$ARCH" ]; then
            echo "Building single $ARCH architecture on $build_arch machine is not supported. Build 'universal' instead"
        fi
    fi

    run_checked ./configure "${flags[@]}"

}

build_and_install() {
    echo
    echo "==== Building and installing Python ===="
    echo

    # A playlist step starts in whatever directory replay was launched from, so
    # the build has to place itself; the sequential path is already here.
    cd "$PYTHON_SRC" || fail "cannot enter $PYTHON_SRC"

    run_checked /usr/bin/make -j8
    run_checked /usr/bin/make install
}

fix_helper_shebangs() {
    echo "Fixing absolute shebangs in helper scripts..."

    local bin_dir="$INSTALL_DIR/bin"
    local python_shebang="#!/usr/bin/env python3"

    local script
    for script in "$bin_dir"/*; do
        # Skip non-regular files and symlinks
        [ -f "$script" ] || continue
        [ -L "$script" ] && continue

        local first_line
        first_line=$(head -n 1 "$script" 2>/dev/null || echo "")
        echo "$first_line" | /usr/bin/grep -q '^#!.*python' || continue

        echo "  Changing shebang in $(basename "$script")"
        /usr/bin/sed -i '' "1s|^#!.*|${python_shebang}|" "$script"
    done
}

fix_pkgconfig() {
    echo "Fixing absolute paths in pkg-config files..."
    local pc_dir="$INSTALL_DIR/lib/pkgconfig"

    local pc
    for pc in "$pc_dir"/*.pc; do
        [ -f "$pc" ] || continue
        [ -L "$pc" ] && continue  # skip symlinks

        echo "  Updating $pc"
        # Replace absolute prefix with ${prefix} (already is) and ensure no hard absolute
        /usr/bin/sed -i '' "s|^prefix=.*|prefix=\${pcfiledir}/../..|" "$pc"  # relative from .pc location
        /usr/bin/sed -i '' "s|$INSTALL_DIR|\${prefix}|g" "$pc"
    done
}

strip_debug_symbols() {
    echo
    echo "==== Stripping debug symbols ===="
    echo

    echo "  From python${MAJOR_MINOR} tool"
    /usr/bin/strip -x -v "$INSTALL_DIR/bin/python${MAJOR_MINOR}"

    echo "  From all .dylib and .so files"
    /usr/bin/find "$INSTALL_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) -exec echo "  Stripping {}" \; -exec /usr/bin/strip -x {} \;
}

make_relocatable() {
    echo
    echo "==== Making libpython and python${MAJOR_MINOR} tool relocatable ===="
    echo

    local lib_name="libpython${MAJOR_MINOR}.dylib"
    local lib_path="lib/${lib_name}"
    local exe="bin/python${MAJOR_MINOR}"

    echo "  Setting ID on $lib_path"
    run_checked /usr/bin/install_name_tool -id "@executable_path/../lib/${lib_name}" "$INSTALL_DIR/$lib_path"

    echo "  Fixing load command in executable $INSTALL_DIR/$exe"
    run_checked /usr/bin/install_name_tool -change "$INSTALL_DIR/lib/${lib_name}" \
                               "@executable_path/../lib/${lib_name}" \
                               "$INSTALL_DIR/$exe"
}

relocate_ssl_extensions() {
    echo
    echo "==== Relocating OpenSSL references in _ssl and _hashlib extensions ===="
    echo

    local dynload_dir="$INSTALL_DIR/lib/python${MAJOR_MINOR}/lib-dynload"
    cd "$dynload_dir" || fail "cannot enter $dynload_dir"

    # Find all potential old OpenSSL paths from the build
    local old_ssl_paths
    old_ssl_paths=$( /usr/bin/find "$OPENSSL_BUILD" -name 'libssl*.dylib' 2>/dev/null | /usr/bin/sort -u )
    
    local old_crypto_paths
    old_crypto_paths=$( /usr/bin/find "$OPENSSL_BUILD" -name 'libcrypto*.dylib' 2>/dev/null | /usr/bin/sort -u )

    if [ -z "$old_ssl_paths" ] && [ -z "$old_crypto_paths" ]; then
        echo "  No build-time OpenSSL dylibs found — nothing to relocate"
        return 0
    fi

    local ext
    local old_path
    for ext in _ssl*.so _hashlib*.so; do
        [ -f "$ext" ] || continue

        echo "  Processing extension: $ext"

        # Fix all libssl references
        if [ -n "$old_ssl_paths" ]; then
            while IFS= read -r old_path; do
                [ -z "$old_path" ] && continue
                local has_ref
                has_ref=$( /usr/bin/otool -L "$ext" | /usr/bin/grep -F "$old_path" || echo "" )
                
                if [ -n "$has_ref" ]; then
                    echo "    Changing libssl: $old_path -> @executable_path/../lib/libssl.dylib"
                    /usr/bin/install_name_tool -change "$old_path" "@executable_path/../lib/libssl.dylib" "$ext"
                fi
            done <<< "$old_ssl_paths"
        fi

        # Fix all libcrypto references
        if [ -n "$old_crypto_paths" ]; then
            while IFS= read -r old_path; do
                [ -z "$old_path" ] && continue
                local has_ref
                has_ref=$( /usr/bin/otool -L "$ext" | /usr/bin/grep -F "$old_path" || echo "" )
                
                if [ -n "$has_ref" ]; then
                    echo "    Changing libcrypto: $old_path -> @executable_path/../lib/libcrypto.dylib"
                    /usr/bin/install_name_tool -change "$old_path" "@executable_path/../lib/libcrypto.dylib" "$ext"
                fi
            done <<< "$old_crypto_paths"
        fi
    done
}

# Remove LC_RPATH entries that point into the build tree.
#
# Python is configured with --with-openssl-rpath=auto, which bakes the build's
# OpenSSL directory into _ssl and _hashlib as a runtime search path. Nothing in
# the finished distribution resolves through it - every dependency is rewritten
# to @executable_path or is a system library - so what it leaves behind is an
# absolute path from the machine that did the build, embedded in a shipped
# binary. It also hides a real hazard: an @rpath-style install name would
# silently keep working on the build machine and nowhere else.
strip_build_rpaths() {
    echo
    echo "==== Removing rpaths that point into the build tree ===="
    echo

    local binary rpath paths removed=0
    local candidates
    candidates=$(/usr/bin/find "$INSTALL_DIR" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \))

    while IFS= read -r binary; do
        [ -z "$binary" ] && continue
        /usr/bin/file "$binary" 2>/dev/null | /usr/bin/grep -q 'Mach-O' || continue

        # Each LC_RPATH prints as "path <value> (offset N)" below the command.
        paths=$(/usr/bin/otool -l "$binary" 2>/dev/null \
            | /usr/bin/grep -A2 'cmd LC_RPATH' \
            | /usr/bin/sed -n 's|^ *path \(.*\) (offset [0-9]*)$|\1|p' \
            | /usr/bin/sort -u)

        [ -z "$paths" ] && continue

        while IFS= read -r rpath; do
            [ -z "$rpath" ] && continue
            case "$rpath" in
                "$BUILD_ROOT"*)
                    echo "  $(/usr/bin/basename "$binary"): removing $rpath"
                    run_checked /usr/bin/install_name_tool -delete_rpath "$rpath" "$binary"
                    removed=$((removed + 1))
                    ;;
            esac
        done <<< "$paths"
    done <<< "$candidates"

    if [ "$removed" -eq 0 ]; then
        echo "  No build-tree rpaths found"
    else
        echo "  Removed $removed rpath entries"
    fi
}

verify_lzma_static() {
    [ "$XZ_VERSION" = "none" ] && return 0

    echo
    echo "==== Verifying _lzma has no dynamic liblzma dependency ===="
    echo

    local dynload_dir="$INSTALL_DIR/lib/python${MAJOR_MINOR}/lib-dynload"
    local found_lzma=false

    local ext
    for ext in "$dynload_dir"/_lzma*.so; do
        [ -f "$ext" ] || continue
        found_lzma=true

        echo "  Checking: $ext"
        local lzma_dylib_ref
        lzma_dylib_ref=$(/usr/bin/otool -L "$ext" | /usr/bin/grep "liblzma" || echo "")

        if [ -n "$lzma_dylib_ref" ]; then
            echo "  ${RED}FAIL: _lzma has dynamic dependency on liblzma:${RESET}"
            echo "  $lzma_dylib_ref"
            exit 1
        else
            echo "  ${GREEN}OK: no dynamic liblzma dependency${RESET}"
        fi
    done

    if ! $found_lzma; then
        # An explicit --lzma-version was given, so a missing extension means the
        # build did not do what was asked. Warning here let a distribution
        # without _lzma pass verification, and under the cache that verdict
        # would then be reused on every later run.
        fail "_lzma extension not found in lib-dynload, but lzma ${XZ_VERSION} was requested"
    fi
}

install_additional_modules() {
    echo
    echo "==== Installing certifi for SSL certificate verification ===="
    echo

    # Fatal: shipping without certifi silently disables certificate verification
    # for anything that relies on it, and a transient PyPI failure would
    # otherwise be recorded by the cache as a completed post-processing step.
    run_checked "${INSTALL_DIR}/bin/python${MAJOR_MINOR}" -m pip install --verbose certifi --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org

	# For universal builds only: install universalPip to enable universal2 module installs later
     if [ "$ARCH" = "universal" ]; then
         echo ""
         echo "  universal build detected; installing universalPip (uPip) for universal2 pip installs"

         # Force regex to build universal2 before uPip (uPip depends on regex)
         echo "  Installing regex as universal2 first..."
         export ARCHFLAGS="-arch x86_64 -arch arm64"
         "${INSTALL_DIR}/bin/python${MAJOR_MINOR}" -m pip install --verbose --no-binary :all: --no-deps regex --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org
         unset ARCHFLAGS

         "${INSTALL_DIR}/bin/python${MAJOR_MINOR}" -m pip install --verbose universalPip --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org

        # Patch the broken uPip script (wrong import: uPip.cli instead of universalPip.cli)
        local upip_script="${INSTALL_DIR}/bin/uPip"
        if [ -f "$upip_script" ]; then
            echo "  Patching uPip script (fixing import from uPip.cli to universalPip.cli)"
            /usr/bin/sed -i '' 's/from uPip.cli/from universalPip.cli/' "$upip_script"
            # Optional: make it executable just in case
            /bin/chmod +x "$upip_script"
            echo "  Patch applied."
        else
            echo "  Warning: uPip script not found after install — skipping patch"
        fi
    else
        echo "  Single-arch build, skipping universalPip installation"
    fi
}

deployment_cleanup() {
    echo
    echo "==== Performing deployment cleanup ===="
    echo

    # Everything below deletes relative to this directory. A playlist step starts
    # in replay's working directory, not here, so a failed cd would aim a series
    # of "rm -rf" at whatever tree the build happened to be launched from.
    cd "$INSTALL_DIR" || fail "cannot enter $INSTALL_DIR"

    echo "  Removing share/man/"
    /bin/rm -rfv share/man

    echo "  Removing config directory (static lib + build files)"
    /bin/rm -rfv lib/python${MAJOR_MINOR}/config-3.14-darwin

    echo "  Removing *-intel64 binaries (universal build)"
    /bin/rm -fv bin/*-intel64

    echo "  Removing always-unneeded stdlib components"
    /bin/rm -rfv lib/python${MAJOR_MINOR}/{tkinter,idlelib,test,ensurepip,venv,distutils/command,turtledemo} \
                 lib/python${MAJOR_MINOR}/turtle.py

    echo "  Removing test/debug extensions"
    /bin/rm -fv lib/python${MAJOR_MINOR}/lib-dynload/_test*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_ctypes_test*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_remote_debugging*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_xxtestfuzz*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/xxlimited*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/xxsubtype*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_testmultiphase*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_testsinglephase*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_testimportmultiple*.so \
                lib/python${MAJOR_MINOR}/lib-dynload/_testclinic_limited*.so

    echo "  Removing all tests directories"
    /usr/bin/find lib/python${MAJOR_MINOR} -type d -name "tests" -exec /bin/rm -rfv {} +

    echo "  Removing precompiled bytecode"
    /usr/bin/find lib/python${MAJOR_MINOR} -type d -name "__pycache__" -exec /bin/rm -rfv {} +
    /usr/bin/find lib/python${MAJOR_MINOR} -name "*.py[co]" -exec /bin/rm -v {} \;
}

verify_universal_binaries() {
    local target_dir="$FINAL_DIR"

    if [ "$ARCH" != "universal" ]; then
        echo
        echo "  Skipping universal binary verification for single-architecture build"
        echo
        return 0
    fi

    echo
    echo "==== Verifying all binaries are universal (arm64 + x86_64) ===="
    echo

    local failed=0
    local total=0
    local binary file_info
    local temp_list="/tmp/verify_binaries_$$"

    local executable_files=$(/usr/bin/find "$target_dir" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \))

    while IFS= read -r binary; do
        [ -z "$binary" ] && continue
        total=$((total + 1))

        file_info=$(/usr/bin/file "$binary" 2>/dev/null)

        is_mach_o=$(echo "$file_info" | /usr/bin/grep -c "Mach-O")
        if [ "$is_mach_o" -eq 0 ]; then
            continue
        fi

        is_universal=$(echo "$file_info" | /usr/bin/grep -c "Mach-O.*universal")
        if [ "$is_universal" -eq 0 ]; then
            echo "  ${RED}FAIL${RESET}: $binary - not universal"
            failed=$((failed + 1))
            continue
        fi

        has_arm64=$(echo "$file_info" | /usr/bin/grep -c "arm64")
        has_x86_64=$(echo "$file_info" | /usr/bin/grep -c "x86_64")
        if [ "$has_arm64" -eq 0 ] || [ "$has_x86_64" -eq 0 ]; then
            echo "  ${RED}FAIL${RESET}: $binary - missing architectures"
            failed=$((failed + 1))
        fi
    done <<< "$executable_files"

    echo
    if [ $failed -gt 0 ]; then
        echo "  ${RED}Verification FAILED: $failed universal binary issues found${RESET}"
        exit 1
    else
        echo "  ${GREEN}All Mach-O binaries verified as universal (arm64 + x86_64)${RESET}"
    fi
}

calc_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        /usr/bin/du -shk "$dir" | cut -f1 | /usr/bin/awk '{printf "%.2f MB\n", $1/1024}'
    else
        echo "0B"
    fi
}

finalize() {
    echo
    echo "==== Moving final installation to $FINAL_DIR ===="
    echo

    /bin/rm -rf "$FINAL_DIR"  # remove dir from prior run if exists
    /bin/mkdir -pv "$(/usr/bin/dirname "$FINAL_DIR")"
    /bin/mv -v "$INSTALL_DIR" "$FINAL_DIR"
}

# The replay build copies instead of moving. Moving would consume the very tree
# the expensive steps declared as their output: the next run would find those
# outputs gone, miss on every one of them, and rebuild Python from scratch -
# which is the whole thing the cache exists to avoid. On APFS "cp -c" clones the
# tree, so the copy costs almost nothing and no space until one side is written.
finalize_copy() {
    echo
    echo "==== Copying final installation to $FINAL_DIR ===="
    echo

    # Test for the interpreter, not just the directory: an earlier phase that
    # failed part way can leave an $INSTALL_DIR containing nothing but the lib/
    # that copy_and_relocate_openssl_dylibs creates, and a -d test would happily
    # publish that empty tree as the finished distribution.
    [ -x "$INSTALL_DIR/bin/python${MAJOR_MINOR}" ] \
        || fail "nothing to finalize: no interpreter at $INSTALL_DIR/bin/python${MAJOR_MINOR}"

    /bin/rm -rf "$FINAL_DIR"  # remove dir from prior run if exists
    /bin/mkdir -pv "$(/usr/bin/dirname "$FINAL_DIR")"

    if /bin/cp -Rc "$INSTALL_DIR" "$FINAL_DIR" 2>/dev/null; then
        echo "  Cloned $INSTALL_DIR -> $FINAL_DIR (copy-on-write)"
    else
        # Not APFS, or a filesystem that cannot clone: fall back to a deep copy.
        # ditto is used rather than cp -R because it carries symlinks, modes and
        # extended attributes across without further flags.
        echo "  Clone unavailable - performing a full copy"
        run_checked /usr/bin/ditto "$INSTALL_DIR" "$FINAL_DIR"
    fi
}

rename_build_artifacts() {
    echo
    echo "==== Renaming build flavor directory to: ${BUILD_FLAVOR_DIR}.last ===="
    echo

    if [ -d "${BUILD_FLAVOR_DIR}.last" ]; then
        /bin/rm -rf "${BUILD_FLAVOR_DIR}.last"
    fi
    /bin/mv -v "$BUILD_FLAVOR_DIR" "${BUILD_FLAVOR_DIR}.last"
}

verify_python_symlinks() {
    echo
    echo "==== Verifying python3 symlink ===="
    echo

    local python3_link="$FINAL_DIR/bin/python3"

    if [ ! -e "$python3_link" ]; then
        echo "  ${RED}FATAL: python3 symlink not found at $python3_link${RESET}"
        echo "  Contents of $FINAL_DIR/bin/:"
        /bin/ls -la "$FINAL_DIR/bin/" 2>/dev/null || echo "  (bin/ directory not found)"
        exit 1
    fi

    if [ ! -x "$python3_link" ]; then
        echo "  ${RED}FATAL: $python3_link exists but is not executable${RESET}"
        exit 1
    fi

    echo "  ${GREEN}OK: python3 found at $python3_link${RESET}"
    /bin/ls -la "$python3_link"
}

run_tests() {
    echo
    echo "==== Running basic sanity tests on the built Python ===="
    echo

    local test_script="${SCRIPT_DIR}/test_custom_python.py"
    local python_bin="$FINAL_DIR/bin/python3"

    if [ ! -f "$test_script" ]; then
        echo "Warning: Test script not found at $test_script - skipping tests"
        return 0
    fi

    echo "  Executing: $python_bin $test_script"
    "$python_bin" "$test_script"
    local test_exit=$?
    if [ $test_exit -ne 0 ]; then
        echo
        echo "  ${RED}FATAL: sanity tests failed — see output above${RESET}"
        exit 1
    fi

    if [ "$ARCH" = "universal" ]; then
        local build_arch
        build_arch=$(/usr/bin/uname -m)

        if [ "$build_arch" = "arm64" ]; then
            local is_rosetta_available=$(/usr/bin/arch -x86_64 /usr/bin/uname -m)
            if [ "$is_rosetta_available" = "x86_64" ]; then
                echo "  Executing Intel code under Rosetta to verify universal binary:"
                echo "  arch --x86_64 $python_bin $test_script"
                /usr/bin/arch --x86_64 "$python_bin" "$test_script"
                local rosetta_exit=$?
                if [ $rosetta_exit -ne 0 ]; then
                    echo
                    echo "  ${RED}FATAL: sanity tests failed under Rosetta — see output above${RESET}"
                    exit 1
                fi
            fi
        fi
    fi
}

print_summary() {
    echo
    echo "==== Build summary ===="
    echo
    echo "Relocatable ${ARCH} Python ${VERSION} ready in: $FINAL_DIR"
    echo "Size: $(calc_size "$FINAL_DIR")"
    echo "Invoke with: $FINAL_DIR/bin/python${MAJOR_MINOR}"
    echo "Next steps:"
    echo "  1. Install modules: ./install_modules.sh --python-dir \"$FINAL_DIR/bin/python${MAJOR_MINOR}\" module"
    echo "  2. Thin further if needed: ./thin_python_distribution.sh \"$FINAL_DIR\" ..."
    echo "  3. Bundle and test in your app"
    echo
}

# ===========================================================================
# Replay build engine
#
# The same build phases, expressed as a playlist instead of a call sequence.
# "replay" reads the file, derives an execution graph from the files each step
# declares it consumes and produces, runs independent steps concurrently, and
# with --cache skips any step whose declared world is unchanged since the last
# run. Nothing below reimplements a build phase: every step re-invokes this
# script with --task, so the sequential path and the playlist path execute the
# very same functions.
# ===========================================================================

# A stamp is an "this step really ran" token. Its content changes on every
# execution, and each coarse in-place phase declares the previous phase's stamp
# as an input, so re-executing one phase always drags its dependents along.
#
# Stamps are what make the in-place phases safe to cache. Those phases mutate a
# shared tree rather than producing a file of their own, and the tempting
# alternative - having post-processing declare the interpreter it strips as an
# input - is wrong in a way that is easy to miss: a re-run of "make install"
# restores a pristine, unstripped, non-relocatable tree, and if the fingerprint
# of that tree happened to match, post-processing would be skipped over it.
write_stamp() {
    local name="$1"
    /bin/mkdir -p "$STAMP_DIR" || fail "cannot create $STAMP_DIR"
    printf '%s pid=%s token=%s\n' \
        "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "${RANDOM}${RANDOM}${RANDOM}" \
        > "${STAMP_DIR}/${name}.stamp" || fail "cannot write stamp: $name"
}

stamp_path() { echo "${STAMP_DIR}/$1.stamp"; }

# --- composite phases, one playlist step each ------------------------------

# configure_python runs "make distclean", which deletes every object file and
# the built library along with the generated makefiles, and then regenerates a
# byte-identical Makefile. Ordering the build behind the Makefile alone would
# therefore let it cache-HIT over a source tree whose objects were just wiped:
# the interpreter it declares still sits in the install directory, untouched by
# distclean, so nothing in its declared world changed. The result would be a
# green build that silently ships the previous distribution - linked against the
# previous OpenSSL, if that is what forced the reconfigure. The stamp closes it.
task_configure_python() {
    configure_python
    write_stamp configure-python
}

task_build_python() {
    build_and_install
    write_stamp build-python
}

# Everything that rewrites the installed tree in place, in the same order the
# sequential build applies it. Kept as one coarse step because these phases
# share a single mutable tree: split apart they would all have to declare the
# same output, which replay rejects, and they are fast next to the build anyway.
task_postprocess() {
    fix_pkgconfig
    make_relocatable
    copy_and_relocate_openssl_dylibs
    relocate_ssl_extensions
    strip_build_rpaths
    verify_lzma_static
    install_additional_modules
    fix_helper_shebangs
    strip_debug_symbols
    deployment_cleanup
    write_stamp postprocess
}

# Assert that nothing in the finished distribution still points into the build
# tree.
#
# The sequential build gets this check for free, and only by accident: it moves
# the install tree out and renames the build directory, so a load command still
# holding a build-time absolute path simply fails to resolve and the sanity
# tests fall over. The replay build cannot do either - both moves would consume
# the outputs the expensive steps declared, forcing a full rebuild every run -
# so those paths stay valid on this machine. The tests would then pass on a
# distribution that loads nowhere else, and the failure would surface only after
# it was bundled into an app. So the property is checked directly rather than
# inferred from the tree having moved.
verify_no_build_paths() {
    echo
    echo "==== Verifying no references into the build tree remain ===="
    echo

    local offenders=0 binary refs rpaths
    local candidates
    candidates=$(/usr/bin/find "$FINAL_DIR" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \))

    while IFS= read -r binary; do
        [ -z "$binary" ] && continue
        /usr/bin/file "$binary" 2>/dev/null | /usr/bin/grep -q 'Mach-O' || continue

        # Dependencies and install names. Only indented lines are examined:
        # otool prints an unindented header per architecture slice naming the
        # file itself, which would match whenever --output puts the finished
        # distribution underneath the build root.
        refs=$(/usr/bin/otool -L "$binary" 2>/dev/null \
            | /usr/bin/grep -E '^[[:space:]]' | /usr/bin/grep -F "$BUILD_ROOT")

        # Runtime search paths. otool -L does not print LC_RPATH at all, so a
        # check built only on it would miss the one load command this build is
        # actually in the habit of leaving behind.
        rpaths=$(/usr/bin/otool -l "$binary" 2>/dev/null \
            | /usr/bin/grep -A2 'cmd LC_RPATH' \
            | /usr/bin/sed -n 's|^ *path \(.*\) (offset [0-9]*)$|\1|p' \
            | /usr/bin/grep -F "$BUILD_ROOT")

        if [ -n "$refs" ] || [ -n "$rpaths" ]; then
            echo "  ${RED}FAIL${RESET}: $binary still references the build tree:"
            [ -n "$refs" ] && echo "$refs"
            [ -n "$rpaths" ] && echo "$rpaths" | /usr/bin/sed 's|^|    LC_RPATH |'
            offenders=$((offenders + 1))
        fi
    done <<< "$candidates"

    if [ "$offenders" -gt 0 ]; then
        fail "$offenders binary/binaries still reference $BUILD_ROOT - the distribution is not relocatable"
    fi

    echo "  ${GREEN}OK: no load command points into $BUILD_ROOT${RESET}"
}

# Declares no outputs, so replay never caches it: the checks and the test suite
# run on every invocation, which is what you want from a verification phase.
task_verify() {
    verify_universal_binaries
    verify_python_symlinks
    verify_no_build_paths
    run_tests
    print_summary
}

# --- single-step entry point -----------------------------------------------

# Invoked as: build-embedded-python.sh --task=NAME --start-dir=... <resolved versions>
# Versions arrive already resolved, so a step never re-runs network detection
# and never disagrees with its siblings about what is being built.
run_task() {
    validate_arch

    if [ "$VERSION" = "auto" ]; then
        fail "--task requires a resolved --version (got \"auto\")"
    fi

    compute_paths

    # A phase is handed only the versions it reads, so any it was not handed
    # still holds its default. Catch the case where that default reached a phase
    # that needed the real value, rather than letting it build a URL containing
    # the word "auto" or silently skip an lzma check that "none" disables.
    case "$TASK" in
        fetch_openssl|unpack_openssl|build_openssl)
            [ "$OPENSSL_VERSION" = "auto" ] && fail "task $TASK requires a resolved --openssl-version"
            ;;
    esac
    case "$TASK" in
        fetch_xz|unpack_xz|build_xz|setup_lzma_module)
            case "$XZ_VERSION" in
                auto|none) fail "task $TASK requires a resolved --lzma-version (got \"$XZ_VERSION\")" ;;
            esac
            ;;
    esac

    # prepare() normally does this; a playlist step never calls prepare.
    /bin/mkdir -p "${PYTHONPYCACHEPREFIX}"

    case "$TASK" in
        fetch_python)        fetch_python ;;
        unpack_python)       unpack_python ;;
        fetch_openssl)       fetch_openssl ;;
        unpack_openssl)      unpack_openssl ;;
        build_openssl)       build_openssl ;;
        fetch_xz)            fetch_xz ;;
        unpack_xz)           unpack_xz ;;
        build_xz)            build_xz ;;
        setup_lzma_module)   setup_lzma_module ;;
        configure_python)    task_configure_python ;;
        build_python)        task_build_python ;;
        postprocess)         task_postprocess ;;
        finalize)            finalize_copy ;;
        verify)              task_verify ;;
        *) fail "unknown --task: $TASK" ;;
    esac
}

# --- playlist generation ---------------------------------------------------

json_escape() {
    printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_string_array() {
    local out="" first=true item
    for item in "$@"; do
        if $first; then first=false; else out="${out}, "; fi
        out="${out}\"$(json_escape "$item")\""
    done
    printf '[%s]' "$out"
}

TASK_ARGS=()

# The command line a step is invoked with, carrying only the resolved values
# that its phase actually reads.
#
# This is deliberately not "pass everything". replay identifies an action by its
# expanded command line, so a parameter a phase never looks at still becomes
# part of its identity: handing --openssl-version to the Python download would
# make bumping OpenSSL re-run the download, the xz build and the lzma module
# setup, none of which have anything to do with OpenSSL. Versions that a phase
# does not read are therefore left out, and the phases that must still re-run
# after such a bump are pulled in by their declared inputs instead, which is the
# honest reason for them to re-run.
#
# --version, --arch and --start-dir go to every step: all three define where the
# build tree lives, and every phase touches it.
set_task_arguments() {
    local task="$1"

    TASK_ARGS=(
        "--task=$task"
        "--start-dir=$START_DIR"
        "--version=$VERSION"
        "--arch=$ARCH"
    )

    # Read by the phases that name the OpenSSL tarball or report its version.
    case "$task" in
        fetch_openssl|unpack_openssl|build_openssl)
            TASK_ARGS+=("--openssl-version=$OPENSSL_VERSION") ;;
    esac

    # Read by the xz phases, and by the phases that branch on whether lzma is
    # being built at all: configure_python adds the include/lib flags for it,
    # and postprocess runs verify_lzma_static only when it is enabled.
    case "$task" in
        fetch_xz|unpack_xz|build_xz|setup_lzma_module|configure_python|postprocess)
            TASK_ARGS+=("--lzma-version=$XZ_VERSION") ;;
    esac

    # Only the phases that place or inspect the finished distribution.
    case "$task" in
        finalize|verify)
            TASK_ARGS+=("--output=$FINAL_DIR") ;;
    esac
}

PLAYLIST_STEPS=()

# add_execute_step TASK [--inputs P...] [--outputs P...]
add_execute_step() {
    local task="$1"; shift
    local -a inputs=() outputs=()
    local bucket="in" arg

    for arg in "$@"; do
        case "$arg" in
            --inputs)  bucket="in";  continue ;;
            --outputs) bucket="out"; continue ;;
        esac
        if [ "$bucket" = "in" ]; then inputs+=("$arg"); else outputs+=("$arg"); fi
    done

    # Every step re-enters this script, and replay's cache identifies an action
    # by its expanded command line rather than by the bytes of the tool it
    # names. Editing a build phase would otherwise leave its stale product
    # cached, so the script is declared an input of every step that runs it.
    inputs+=("$SCRIPT_PATH")

    set_task_arguments "$task"
    local -a args=("${TASK_ARGS[@]}")

    local step="  {
    \"action\": \"execute\",
    \"tool\": \"$(json_escape "$SCRIPT_PATH")\",
    \"arguments\": $(json_string_array "${args[@]}"),
    \"inputs\": $(json_string_array "${inputs[@]}")"

    if [ ${#outputs[@]} -gt 0 ]; then
        step="${step},
    \"outputs\": $(json_string_array "${outputs[@]}")"
    fi

    step="${step}
  }"

    PLAYLIST_STEPS+=("$step")
}

# replay expands ${VAR} in every path it is handed and treats an unresolvable
# one as a hard error. The generated playlist carries fully expanded absolute
# paths, so a literal "${" anywhere in a build path would be read as a variable
# reference that was never meant to be one.
check_paths_for_variable_syntax() {
    local p
    # SCRIPT_PATH is included because it is the "tool" of every action and an
    # entry in every inputs array: a checkout under a directory containing "${"
    # would produce a playlist replay rejects outright.
    for p in "$START_DIR" "$FINAL_DIR" "$SCRIPT_PATH"; do
        case "$p" in
            *'${'*) fail "path contains \${...}, which replay would try to expand: $p" ;;
        esac
    done
}

generate_playlist() {
    local playlist="$1"

    PLAYLIST_STEPS=()

    local py_tarball ossl_tarball xz_tarball
    py_tarball=$(python_tarball_path)
    ossl_tarball=$(openssl_tarball_path)
    xz_tarball=$(xz_tarball_path)

    local py_configure="$PYTHON_SRC/configure"
    local py_makefile="$PYTHON_SRC/Makefile"
    local setup_local="$PYTHON_SRC/Modules/Setup.local"
    local ossl_configure="$OPENSSL_SRC/Configure"
    local libssl="$OPENSSL_INSTALL/lib/libssl.dylib"
    local libcrypto="$OPENSSL_INSTALL/lib/libcrypto.dylib"
    local xz_configure="$XZ_SRC/configure"
    local liblzma="$XZ_INSTALL/lib/liblzma.a"
    local python_exe="$INSTALL_DIR/bin/python${MAJOR_MINOR}"
    local libpython="$INSTALL_DIR/lib/libpython${MAJOR_MINOR}.dylib"
    local final_exe="$FINAL_DIR/bin/python${MAJOR_MINOR}"

    # The real compiler behind /usr/bin/clang, which is only a stub that does
    # not change when Xcode does. Declaring it makes a toolchain upgrade
    # invalidate everything compiled with the previous one.
    local -a toolchain=()
    local clang_path
    clang_path=$(/usr/bin/xcrun --find clang 2>/dev/null)
    if [ -n "$clang_path" ] && [ -f "$clang_path" ]; then
        toolchain=("$clang_path")
    fi

    # Python and OpenSSL are fetched, unpacked and built independently of each
    # other; the graph replay derives from these declarations is what lets the
    # two dependency builds and the three downloads overlap.
    add_execute_step fetch_python  --outputs "$py_tarball"
    add_execute_step unpack_python --inputs "$py_tarball" --outputs "$py_configure"

    add_execute_step fetch_openssl  --outputs "$ossl_tarball"
    add_execute_step unpack_openssl --inputs "$ossl_tarball" --outputs "$ossl_configure"
    add_execute_step build_openssl \
        --inputs "$ossl_configure" ${toolchain[@]+"${toolchain[@]}"} \
        --outputs "$libssl" "$libcrypto"

    # Inputs of the Python configure step, grown as the optional pieces are
    # switched on. Declaration order does not matter; presence does.
    local -a configure_inputs=("$py_configure" "$libssl" "$libcrypto")

    if [ "$XZ_VERSION" != "none" ]; then
        add_execute_step fetch_xz  --outputs "$xz_tarball"
        add_execute_step unpack_xz --inputs "$xz_tarball" --outputs "$xz_configure"
        add_execute_step build_xz \
            --inputs "$xz_configure" ${toolchain[@]+"${toolchain[@]}"} \
            --outputs "$liblzma"
        add_execute_step setup_lzma_module \
            --inputs "$liblzma" "$py_configure" \
            --outputs "$setup_local"

        configure_inputs+=("$liblzma" "$setup_local")
    fi

    add_execute_step configure_python \
        --inputs "${configure_inputs[@]}" ${toolchain[@]+"${toolchain[@]}"} \
        --outputs "$py_makefile" "$(stamp_path configure-python)"

    # Gated on the stamp rather than on the Makefile: configure regenerates that
    # file byte-identically after distclean has deleted the object tree, so the
    # Makefile alone cannot tell the build that its inputs are gone.
    #
    # The interpreter and libpython are declared as outputs even though the next
    # step strips and relocates them in place. replay snapshots a step's owned
    # paths at the end of the run, after the mutation, so the pair settles at a
    # fixed point and both skip on an unchanged rerun. Declaring them is what
    # makes deleting the install tree rebuild it.
    add_execute_step build_python \
        --inputs "$(stamp_path configure-python)" ${toolchain[@]+"${toolchain[@]}"} \
        --outputs "$python_exe" "$libpython" "$(stamp_path build-python)"

    # The bundled OpenSSL dylibs are both a real input (they are copied in from
    # the OpenSSL install) and a real product (the copies are stripped and given
    # relative install names). Declaring the copies as outputs is what notices
    # that someone deleted them from the install tree; the originals are read
    # and never modified, so declaring them as inputs is safe.
    add_execute_step postprocess \
        --inputs "$(stamp_path build-python)" "$libssl" "$libcrypto" \
        --outputs "$(stamp_path postprocess)" \
                  "$INSTALL_DIR/lib/libssl.dylib" "$INSTALL_DIR/lib/libcrypto.dylib"

    # Whole directories, not just the interpreter. The install tree is what is
    # actually copied, and the output tree is what must be rebuilt if anything
    # in it moved - which it routinely does, since the summary this build prints
    # points at install_modules.sh and thin_python_distribution.sh, and neither
    # of those touches bin/python3.X. Declaring only the interpreter would let a
    # thinned or extended distribution survive a rebuild that was meant to
    # replace it.
    add_execute_step finalize \
        --inputs "$(stamp_path postprocess)" "$INSTALL_DIR" \
        --outputs "$FINAL_DIR"

    # No declared outputs: never cached, so the tests run every time.
    add_execute_step verify --inputs "$final_exe"

    /bin/mkdir -p "$(/usr/bin/dirname "$playlist")" || fail "cannot create playlist directory"

    {
        echo "["
        local i last=$(( ${#PLAYLIST_STEPS[@]} - 1 ))
        for (( i = 0; i <= last; i++ )); do
            printf '%s' "${PLAYLIST_STEPS[i]}"
            if [ "$i" -lt "$last" ]; then echo ","; else echo; fi
        done
        echo "]"
    } > "$playlist" || fail "cannot write playlist: $playlist"

    echo "  Playlist written: $playlist (${#PLAYLIST_STEPS[@]} steps)"
}

# --- driver ----------------------------------------------------------------

# Resolve every "auto" version once, up front. The playlist then carries
# concrete versions in each step's command line, which both keeps the steps
# consistent with one another and makes a version bump change the identity of
# every action that depended on it.
resolve_versions() {
    echo
    echo "==== Resolving versions ===="
    echo

    if [ "$VERSION" = "auto" ]; then
        detect_latest_python
    fi

    compute_paths   # MAJOR_MINOR is needed by the OpenSSL constraint check

    if [ "$OPENSSL_VERSION" = "auto" ]; then
        detect_latest_openssl
    fi
    enforce_openssl_version_constraint

    if [ "$XZ_VERSION" = "auto" ]; then
        detect_latest_xz
    fi

    echo "  Python  : $VERSION"
    echo "  OpenSSL : $OPENSSL_VERSION"
    if [ "$XZ_VERSION" = "none" ]; then
        echo "  lzma    : not built"
    else
        echo "  lzma    : $XZ_VERSION"
    fi
}

build_with_replay() {
    echo
    echo "==== Starting build (replay engine) ===="
    echo

    validate_arch
    resolve_versions
    check_paths_for_variable_syntax

    local tools_dir="${BUILD_ROOT}/tools"
    local playlist="${BUILD_FLAVOR_DIR}/build-playlist.json"
    local cache_dir="${BUILD_ROOT}/.replay-cache"

    /bin/mkdir -pv "${PYTHONPYCACHEPREFIX}"
    /bin/mkdir -pv "$DOWNLOAD_DIR"
    /bin/mkdir -pv "$BUILD_FLAVOR_DIR"

    echo
    echo "Python version : $VERSION"
    echo "Target architecture : $ARCH"
    echo "Build root     : $BUILD_ROOT"
    echo "Downloads      : $DOWNLOAD_DIR"
    echo "Build flavor dir : $BUILD_FLAVOR_DIR"
    echo "Final output   : $FINAL_DIR"
    echo

    local bootstrap="${SCRIPT_DIR}/replay_bootstrap.sh"
    [ -x "$bootstrap" ] || fail "replay_bootstrap.sh not found or not executable: $bootstrap"

    local replay_bin
    replay_bin=$("$bootstrap" \
        --min-version="$REPLAY_MIN_VERSION" \
        --tools-dir="$tools_dir" \
        --method="$REPLAY_BOOTSTRAP_METHOD") || fail "could not obtain replay >= $REPLAY_MIN_VERSION"

    echo
    echo "==== Generating playlist ===="
    echo
    generate_playlist "$playlist"

    local -a replay_args=()
    $REPLAY_SERIAL  && replay_args+=(--serial)
    $REPLAY_VERBOSE && replay_args+=(--verbose)
    $REPLAY_DRY_RUN && replay_args+=(--dry-run)
    [ -n "$REPLAY_MAX_TASKS" ] && replay_args+=(--max-tasks "$REPLAY_MAX_TASKS")

    # Stop at the first failure. A build is a dependency chain: letting later
    # steps run against a half-built tree only buries the real error.
    replay_args+=(--stop-on-error)

    if $REPLAY_CACHE; then
        replay_args+=(--cache --cache-dir "$cache_dir")
        $REPLAY_CACHE_REFRESH && replay_args+=(--cache-refresh)
    fi

    echo
    echo "==== Executing playlist ===="
    echo "  $replay_bin ${replay_args[*]} $playlist"
    echo

    "$replay_bin" ${replay_args[@]+"${replay_args[@]}"} "$playlist"
    local status=$?

    if [ $status -ne 0 ]; then
        echo
        echo "  ${RED}Playlist execution failed (exit $status)${RESET}"
        exit $status
    fi

    if $REPLAY_DRY_RUN; then
        echo
        echo "  Dry run only - nothing was built."
        echo
    fi

    return 0
}

main() {
    prepare
    download_python
    download_openssl
    build_openssl
    download_xz
    build_xz
    setup_lzma_module
    configure_python
    build_and_install
    fix_pkgconfig
    make_relocatable
    copy_and_relocate_openssl_dylibs
    relocate_ssl_extensions
    strip_build_rpaths
    verify_lzma_static
    install_additional_modules
    fix_helper_shebangs
    strip_debug_symbols
    deployment_cleanup
    finalize
    rename_build_artifacts
    verify_universal_binaries
    verify_python_symlinks
    run_tests
    print_summary
}

if [ -n "$TASK" ]; then
    run_task
elif $USE_REPLAY; then
    build_with_replay
else
    main
fi
