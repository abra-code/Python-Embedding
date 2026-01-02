#!/bin/bash
# thin_python_distribution.sh
# Optional further thinning of a relocatable Python embed after main build and customization.
# Usage: ./thin_python_distribution.sh /path/to/Python-* [component1 component2 ...]
#   Without arguments: prints this help.

set -euo pipefail

EMBED_DIR="${1:-}"
shift || true

calc_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        /usr/bin/du -shk "$dir" | cut -f1 | /usr/bin/awk '{printf "%.2f MB\n", $1/1024}'
    else
        echo "0B"
    fi
}

if [ -z "$EMBED_DIR" ] || [ ! -d "$EMBED_DIR" ]; then
    cat <<HELP
Usage: $0 /path/to/Python-* [component1 component2 ...]

Removes potentially unneeded components (pure-Python modules + extensions).
The main build script already removes always-unneeded parts (tkinter, test suite, ensurepip, venv, etc.).

Common optional removals (verify your app/scripts do not need them):

  ssl             - TLS/HTTPS support (~4MB _ssl.so + ssl.py)
  hashlib         - Accelerated modern crypto hashes (SHA3, BLAKE2, etc.; ~3MB _hashlib.so + hashlib.py)
  sqlite3         - SQLite database support (~1MB _sqlite3.so + sqlite3/ dir)
  curses          - Terminal handling (ncurses bindings); rarely used in GUI/desktop apps (~170KB _curses*.so + curses/ dir)
  xml             - XML parsers (dom/sax/etree); sizable if unused (~448KB + pyexpat.so)
  dbm             - Simple key-value databases (~36KB + _dbm/_gdbm.so)
  decimal         - High-precision decimal arithmetic (~353KB _decimal.so + decimal.py)
  ctypes          - Foreign function interface (calls C libraries; ~186KB _ctypes.so + ctypes/ dir)
  multiprocessing - Parallel execution (~408KB multiprocessing/ dir)
  unittest        - Testing framework (~284KB unittest/ dir)
  xmlrpc          - XML-RPC client/server (deprecated; ~88KB xmlrpc/ dir)
  pip             - Package manager (~20-30MB with deps)
  setuptools      - Packaging tools
  certifi         - CA certificate bundle (breaks HTTPS verification if removed)

  codecs_east_asian - East-Asian text encodings (_codecs_jp/cn/hk/kr/tw.so; ~800KB total)

Any unknown component name is treated generically: removes matching directory, .py file, and related *.so extensions if found.

Note: Removing ssl/hashlib breaks HTTPS and modern crypto.
      Removing certifi breaks SSL certificate verification.

Example:
  $0 ./PythonEmbed-3.14.2-arm64 ssl hashlib sqlite3 pip curses xml

HELP
    exit 1
fi

echo "Current size of $EMBED_DIR: $(calc_size "$EMBED_DIR")"
echo

PYTHON_VER=$(basename "$EMBED_DIR"/lib/python* | sed 's/python//')
LIB_DIR="$EMBED_DIR/lib/python${PYTHON_VER}"
SITE_PKGS="$LIB_DIR/site-packages"
DYNLOAD="$LIB_DIR/lib-dynload"

echo "Further thinning $EMBED_DIR (Python $PYTHON_VER)"
echo

for comp in "$@"; do
    echo "Processing component: $comp"
    removed=false

    # Directory
    if [ -d "$LIB_DIR/$comp" ]; then
        echo "  Removing directory: $LIB_DIR/$comp"
        /bin/rm -rf "$LIB_DIR/$comp"
        removed=true
    fi

    # .py file
    if [ -f "$LIB_DIR/${comp}.py" ]; then
        echo "  Removing module file: $LIB_DIR/${comp}.py"
        /bin/rm -f "$LIB_DIR/${comp}.py"
        removed=true
    fi

    # Related extensions
    if ls "$DYNLOAD"/*"${comp}"*.so >/dev/null 2>&1; then
        for so in "$DYNLOAD"/*"${comp}"*.so; do
            echo "  Removing extension: $so"
        done
        /bin/rm -f "$DYNLOAD"/*"${comp}"*.so
        removed=true
    fi

    # site-packages special case
    if [[ "$comp" == pip || "$comp" == setuptools || "$comp" == certifi ]]; then
        if ls "$SITE_PKGS/${comp}"* >/dev/null 2>&1; then
            for item in "$SITE_PKGS/${comp}"*; do
                echo "  Removing site-packages item: $item"
            done
            /bin/rm -rf "$SITE_PKGS/${comp}"*
            removed=true
        fi
    fi

    if [[ "$comp" == "ssl" ]]; then
        # Can safely remove libssl.dylib
        [ -f "$EMBED_DIR/lib/libssl.dylib" ] && echo "  Removing libssl.dylib" && /bin/rm -f "$EMBED_DIR/lib/libssl.dylib"
    fi
    
    # Track if anything needs libcrypto
    needs_crypto=false
    for c in "$@"; do [[ "$c" == "ssl" || "$c" == "hashlib" ]] && needs_crypto=true; done
    
    if ! $needs_crypto && [ -f "$EMBED_DIR/lib/libcrypto.dylib" ]; then
        echo "  Removing unused libcrypto.dylib"
        /bin/rm -f "$EMBED_DIR/lib/libcrypto.dylib"
    fi

    # codecs_east_asian bundle
    if [ "$comp" = "codecs_east_asian" ]; then
        for codec in jp cn hk kr tw; do
            if ls "$DYNLOAD/_codecs_${codec}"*.so >/dev/null 2>&1; then
                for so in "$DYNLOAD/_codecs_${codec}"*.so; do
                    echo "  Removing East-Asian codec extension: $so"
                done
                /bin/rm -f "$DYNLOAD/_codecs_${codec}"*.so
                removed=true
            fi
        done
    fi

    if ! $removed; then
        echo "  No matching files found for '$comp'"
    fi
    echo
done

echo "Final size of $EMBED_DIR: $(calc_size "$EMBED_DIR")"
echo "Optional thinning complete."
