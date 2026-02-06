#!/bin/bash
# install_modules.sh
# Installs additional modules in a relocatable Python distribution for macOS.

set -uo pipefail

RED=$(printf '\033[91m')
GREEN=$(printf '\033[92m')
RESET=$(printf '\033[0m')

PYTHON_DIR=""
MODULES=()

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] MODULE [MODULE ...]

Options:
  --python-dir=PATH   Path to the relocatable Python distribution (required)
  --help              Show this help message

Example:
  ./install_modules.sh --python-dir=/path/to/Python-3.13.0-universal numpy pandas
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) show_help ;;
        --python-dir=*) PYTHON_DIR="${1#*=}" ;;
        --python-dir) shift; PYTHON_DIR="$1" ;;
        *) MODULES+=("$1") ;;
    esac
    shift
done

# Normalize PYTHON_DIR to absolute path
if [ -n "${PYTHON_DIR}" ]; then
    PYTHON_DIR=$(/bin/realpath "${PYTHON_DIR}")
fi

if [ -z "$PYTHON_DIR" ] || [ ${#MODULES[@]} -eq 0 ]; then
    echo "Error: --python-dir with a valid directory and at least one module are required."
    show_help
fi

PYTHON_BIN="${PYTHON_DIR}/bin/python3"

if [ ! -f "$PYTHON_BIN" ]; then
    echo "Error: Python binary not found at $PYTHON_BIN"
    exit 1
fi

# Extract MAJOR_MINOR from the Python version
MAJOR_MINOR=$("$PYTHON_BIN" --version | awk '{print $2}' | cut -d. -f1-2)

if [ -z "$MAJOR_MINOR" ]; then
    echo "Error: Unable to determine Python version from 'python3 --version'."
    exit 1
fi

is_python_universal() {
    local main_binary="${PYTHON_DIR}/lib/libpython${MAJOR_MINOR}.dylib"
    if [ ! -f "$main_binary" ]; then
        main_binary="${PYTHON_DIR}/bin/python${MAJOR_MINOR}"
    fi

    if [ ! -f "$main_binary" ]; then
        return 1
    fi

    local main_info=$(/usr/bin/lipo -info "$main_binary" 2>&1)
    if echo "$main_info" | /usr/bin/grep -q "Architectures in the fat file"; then
        return 0
    fi
    return 1
}

is_python_universal
IS_UNIVERSAL=$?

install_modules() {
    echo
    echo "==== Installing modules: ${MODULES[*]} ===="
    echo

    local upip_bin="${PYTHON_DIR}/bin/uPip"

    if [ -x "$upip_bin" ] && [ $IS_UNIVERSAL -eq 0 ]; then
        echo "  uPip found — installing one module at a time (no --trusted-host support)"

        local mod
        for mod in "${MODULES[@]}"; do
            echo "    Installing $mod via uPip"
            "${PYTHON_BIN}" "$upip_bin" --install "$mod"
            local upip_result=$?
            if [ $upip_result -ne 0 ]; then
                echo "      uPip failed (exit $upip_result) — falling back to pip with ARCHFLAGS=\"-arch x86_64 -arch arm64\""
                export ARCHFLAGS="-arch x86_64 -arch arm64"
                "${PYTHON_BIN}" -m pip install --no-binary :all: --force-reinstall "$mod" \
                    --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org
                unset ARCHFLAGS
            fi
        done
    else
        
        if [ $IS_UNIVERSAL -eq 0 ]; then
            echo "  uPip not found — using regular pip"
            export ARCHFLAGS="-arch x86_64 -arch arm64"
            "${PYTHON_BIN}" -m pip install --no-binary :all: --force-reinstall \
                --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org \
                "${MODULES[@]}"
            unset ARCHFLAGS
        else
            "${PYTHON_BIN}" -m pip install --verbose \
                --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org \
                "${MODULES[@]}"
        fi
    fi
}

remove_pycache() {
    echo ""
    echo "Removing __pycache__ and .pyc objects..."
    echo ""

    /usr/bin/find "${PYTHON_DIR}/lib/python${MAJOR_MINOR}" -type d -name "__pycache__" -exec /bin/rm -rfv {} +
    /usr/bin/find "${PYTHON_DIR}/lib/python${MAJOR_MINOR}" -name "*.py[co]" -exec /bin/rm -v {} \;
}

fix_helper_shebangs() {
    echo ""
    echo "Fixing absolute shebangs in helper scripts..."
    echo ""

    local bin_dir="$PYTHON_DIR/bin"
    local python_shebang="#!/usr/bin/env python3"

    for script in "$bin_dir"/*; do
        # Skip non-regular files and symlinks
        [ -f "$script" ] || continue
        [ -L "$script" ] && continue

        local first_line=$(head -n 1 "$script" 2>/dev/null || echo "")
        echo "$first_line" | /usr/bin/grep -q '^#!.*python' || continue

        echo "  Changing shebang in $(basename "$script")"
        /usr/bin/sed -i '' "1s|^#!.*|${python_shebang}|" "$script"
    done
}

make_relocatable() {
    echo ""
    echo "Fixing absolute references in .so and .dylib linkage (recursive, only internal deps)..."
    echo ""

    local lib_root="$PYTHON_DIR/lib"
    local changed=0

    local found_libraries=$(/usr/bin/find "$lib_root" -type f \( -name "*.so" -o -name "*.dylib" \))

    if [ -z "$found_libraries" ]; then
        echo "  No .so or .dylib files found."
        return
    fi

    while IFS= read -r file; do
        # Skip empty lines (in case find adds trailing newline)
        [ -z "$file" ] && continue

        local rel_path="${file#$PYTHON_DIR/}"
        local file_name="${file##*/}"

        /usr/bin/install_name_tool -id "@executable_path/../$rel_path" "$file" 2>/dev/null

        local dependencies=$(/usr/bin/otool -L "$file" | /usr/bin/awk '/^[ \t]+[\/@]/ {print $1}')

        local file_changed=0
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            if [[ "$dep" == "$PYTHON_DIR/"* ]]; then
                local dep_rel="${dep#$PYTHON_DIR/}"
                echo "  In $file_name: changing $dep to @executable_path/../$dep_rel"
                /usr/bin/install_name_tool -change "$dep" "@executable_path/../$dep_rel" "$file"
                ((file_changed++))
                ((changed++))
            fi
        done <<< "$dependencies"
    done <<< "$found_libraries"

    if ((changed == 0)); then
        echo "  No internal absolute paths needed fixing."
    else
        echo "  Fixed $changed internal linkage reference(s)."
    fi
}

strip_debug_symbols() {
    echo
    echo "==== Stripping debug symbols from .so and .dylib files ===="
    echo

    echo "  From all .dylib and .so files"
    /usr/bin/find "$PYTHON_DIR" -type f \( -name "*.dylib" -o -name "*.so" \) -exec echo "  Stripping {}" \; -exec /usr/bin/strip -x {} \;
}

verify_universal_binaries() {
    local target_dir="$PYTHON_DIR"

    if [ $IS_UNIVERSAL -ne 0 ]; then
        echo
        echo "  Skipping universal verification — Python is not universal"
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

main() {
    install_modules

    echo ""
    echo "==== Performing post-installation cleanup ===="
    echo ""

    remove_pycache
    fix_helper_shebangs
    make_relocatable
    strip_debug_symbols
    verify_universal_binaries
}

main
