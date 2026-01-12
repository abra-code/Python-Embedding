#!/bin/bash
# thin_python_distribution.sh
# Optional thinning of a relocatable Python + optional single-arch slicing.
# Usage: ./thin_python_distribution.sh [--arch arm64|x86_64] /path/to/Python [component1 component2 ...]
#   Without arguments: prints this help.

set -euo pipefail

ARCH=""
PYTHON_DIR=""
COMPONENTS=()

calc_size() {
    local dir="$1"
    if [ -d "$dir" ]; then
        /usr/bin/du -shk "$dir" | /usr/bin/cut -f1 | /usr/bin/awk '{printf "%.2f MB\n", $1/1024}'
    else
        echo "0B"
    fi
}

show_help() {
    cat <<HELP
Usage: $0 [--arch arm64|x86_64] /path/to/Python [component1 component2 ...]

Removes potentially unneeded components (pure-Python modules + extensions).
The main build script already removes always-unneeded parts (tkinter, test suite, ensurepip, venv, etc.).

If --arch is given, thins ALL universal/fat Mach-O binaries in the distribution to single architecture.

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
  $0 --arch=arm64 ./Python-3.14.2-universal ssl hashlib sqlite3 pip
  $0 ./Python-3.14.2-arm64 xml curses decimal

HELP
    exit 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch=*)
                ARCH="${1#*=}"
                if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
                    echo "Error: --arch must be 'arm64' or 'x86_64'"
                    exit 1
                fi
                shift
                ;;
            --arch)
                ARCH="$2"
                if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
                    echo "Error: --arch must be 'arm64' or 'x86_64'"
                    exit 1
                fi
                shift 2
                ;;
            *)
                if [[ -z "$PYTHON_DIR" ]]; then
                    PYTHON_DIR="$1"
                    shift
                else
                    # Remaining arguments are components
                    COMPONENTS+=("$1")
                    shift
                fi
                ;;
        esac
    done

    if [ -z "$PYTHON_DIR" ] || [ ! -d "$PYTHON_DIR" ]; then
        show_help
    fi
}

thin_to_single_arch() {
    local arch="$1"
    echo "Thinning all universal Mach-O files to $arch ..."
    
    # Collect all candidate binary files
    local executable_files=$(/usr/bin/find "$PYTHON_DIR" -type f \( -name '*.dylib' -o -name '*.so' -o -perm +111 \))

    local thinned=0
    local file
    
    # Process each candidate file
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        # Check if file is a universal Mach-O binary
        local file_info=$(/usr/bin/file "$file" 2>/dev/null)
        
        local is_universal=$(echo "$file_info" | /usr/bin/grep -c "Mach-O.*universal")
        
        if [ "$is_universal" -gt 0 ]; then
            echo "  Thinning: $file"
            local tmp="$file.thin.tmp"
            
            set +e
            /usr/bin/lipo -thin "$arch" "$file" -output "$tmp" 2>/dev/null
            local lipo_result=$?
            set -e
            
            if [ $lipo_result -eq 0 ]; then
                /bin/mv "$tmp" "$file"
                ((thinned++))
            else
                echo "    Warning: lipo -thin $arch failed on $file (arch possibly missing)"
                /bin/rm -f "$tmp"
            fi
        fi
    done <<< "$executable_files"
    
    echo "  Thinned $thinned files to $arch."
    echo
}

remove_component() {
    local comp="$1"
    local lib_dir="$2"
    local dynload="$3"
    local site_pkgs="$4"
    
    echo "Processing component: $comp"
    local removed=false

    # Remove directory
    if [ -d "$lib_dir/$comp" ]; then
        echo "  Removing directory: $lib_dir/$comp"
        /bin/rm -rf "$lib_dir/$comp"
        removed=true
    fi

    # Remove .py file
    if [ -f "$lib_dir/${comp}.py" ]; then
        echo "  Removing module file: $lib_dir/${comp}.py"
        /bin/rm -f "$lib_dir/${comp}.py"
        removed=true
    fi

    # Remove related extensions
    local so_files=$(/usr/bin/find "$dynload" -maxdepth 1 -name "*${comp}*.so" 2>/dev/null || echo "")
    
    if [ -n "$so_files" ]; then
        local so_file
        while IFS= read -r so_file; do
            [ -z "$so_file" ] && continue
            echo "  Removing extension: $so_file"
            /bin/rm -f "$so_file"
            removed=true
        done <<< "$so_files"
    fi

    # Handle site-packages special cases
    if [[ "$comp" == "pip" || "$comp" == "setuptools" || "$comp" == "certifi" ]]; then
        local site_items=$(/usr/bin/find "$site_pkgs" -maxdepth 1 -name "${comp}*" 2>/dev/null || echo "")
        
        if [ -n "$site_items" ]; then
            local item
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                echo "  Removing site-packages item: $item"
                /bin/rm -rf "$item"
                removed=true
            done <<< "$site_items"
        fi
    fi

    # Handle SSL-specific cleanup
    if [[ "$comp" == "ssl" ]]; then
        if [ -f "$PYTHON_DIR/lib/libssl.dylib" ]; then
            echo "  Removing libssl.dylib"
            /bin/rm -f "$PYTHON_DIR/lib/libssl.dylib"
            removed=true
        fi
    fi

    # Handle East Asian codecs
    if [ "$comp" = "codecs_east_asian" ]; then
        local codec
        for codec in jp cn hk kr tw; do
            local codec_files
            codec_files=$(/usr/bin/find "$dynload" -maxdepth 1 -name "_codecs_${codec}*.so" 2>/dev/null || echo "")
            
            if [ -n "$codec_files" ]; then
                local codec_file
                while IFS= read -r codec_file; do
                    [ -z "$codec_file" ] && continue
                    echo "  Removing East-Asian codec extension: $codec_file"
                    /bin/rm -f "$codec_file"
                    removed=true
                done <<< "$codec_files"
            fi
        done
    fi

    if ! $removed; then
        echo "  No matching files found for '$comp'"
    fi
    echo
}

check_and_remove_libcrypto() {
    local components=("$@")
    
    # Check if BOTH ssl and hashlib are being removed
    local removing_ssl=false
    local removing_hashlib=false
    local comp
    for comp in "${components[@]}"; do
        if [[ "$comp" == "ssl" ]]; then
            removing_ssl=true
        elif [[ "$comp" == "hashlib" ]]; then
            removing_hashlib=true
        fi
    done
    
    # Only remove libcrypto if both ssl and hashlib are being removed
    if $removing_ssl && $removing_hashlib; then
        if [ -f "$PYTHON_DIR/lib/libcrypto.dylib" ]; then
            echo "Removing libcrypto.dylib (both ssl and hashlib removed)"
            /bin/rm -f "$PYTHON_DIR/lib/libcrypto.dylib"
            echo
        fi
    fi
}

thin_components() {
    local components=("$@")
    local lib_dir=$(echo "${PYTHON_DIR}/lib/python"*)
    local site_pkgs="${lib_dir}/site-packages"
    local dynload="${lib_dir}/lib-dynload"
    
    echo "Thinning $PYTHON_DIR"
    echo
    
    local comp
    for comp in "${components[@]}"; do
        remove_component "$comp" "$lib_dir" "$dynload" "$site_pkgs"
    done
    
    check_and_remove_libcrypto "${components[@]}"
}

main() {
    parse_arguments "$@"
    
    local initial_size=$(calc_size "$PYTHON_DIR")
    echo "Current size of $PYTHON_DIR: $initial_size"
    echo
        
    # Perform component removal if any components specified
    if [ ${#COMPONENTS[@]} -gt 0 ]; then
        thin_components "${COMPONENTS[@]}"
    fi

    # Perform architecture thinning if requested
    if [[ -n "$ARCH" ]]; then
        thin_to_single_arch "$ARCH"
    fi

    local final_size=$(calc_size "$PYTHON_DIR")
    echo "Final size of $PYTHON_DIR: $final_size"
    echo
}

main "$@"
