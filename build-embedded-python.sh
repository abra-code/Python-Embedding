#!/bin/bash
# build-embedded-python.sh
# Builds a minimal, relocatable deployment-only Python for macOS embedding.

set -euo pipefail

GREEN="\033[92m"
RED="\033[91m"
RESET="\033[0m"

VERSION="auto"
ARCH="universal"
OPENSSL_VERSION="auto"

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --version=VERSION   Python version to build (default: auto-detect latest stable)
  --arch=ARCH         Architecture: universal, arm64, or x86_64 (default: universal)
                      Note: cross-compilation, e.g. building x86_64 on Apple Silicon Macs
                            is not supported by Python build system. Build universal instead
  --openssl-version=VERSION   OpenSSL version (default: auto-detect latest stable)
  --help              Show this help message

Example:
  ./build-embedded-python.sh --version=3.13.0 --arch=arm64
  ./build-embedded-python.sh --version=auto --arch=universal
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
        *) echo "Unknown option: $1"; show_help ;;
    esac
    shift
done

MACOSX_DEPLOYMENT_TARGET="11.0"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" >/dev/null 2>&1 && pwd)"  # absolute path to script dir
START_DIR="$(pwd)"  # invocation directory

# this env var prevents creating .pyc precompiled files in the installation location
export PYTHONPYCACHEPREFIX='/tmp/Pyc'

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

prepare() {
    echo
    echo "==== Starting build ===="
    echo

    case "$ARCH" in
        universal|arm64|x86_64) ;;
        *) echo "Invalid ARCH: $ARCH (must be universal, arm64, or x86_64)"; exit 1 ;;
    esac

    # Auto-detect Python version if needed
    if [[ "$VERSION" == "auto" ]]; then
        detect_latest_python
    fi

    # Now we can set MAJOR_MINOR and build paths
    MAJOR_MINOR=$(echo "$VERSION" | cut -d. -f1-2)
    
    # Build directory structure
    BUILD_ROOT="${START_DIR}/build"
    DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
    BUILD_FLAVOR_DIR="${BUILD_ROOT}/python-${VERSION}-${ARCH}"
    PYTHON_SRC="${BUILD_FLAVOR_DIR}/src"
    OPENSSL_BUILD="${BUILD_FLAVOR_DIR}/openssl-build"
    OPENSSL_INSTALL="${BUILD_FLAVOR_DIR}/openssl-install"
    INSTALL_DIR="${BUILD_FLAVOR_DIR}/install"
    FINAL_DIR="${START_DIR}/Python-${VERSION}-${ARCH}"

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

download_python() {
    echo
    echo "==== Downloading Python source ===="
    echo
    
    /bin/mkdir -pv "$DOWNLOAD_DIR" "$PYTHON_SRC"
    local tarball="$DOWNLOAD_DIR/Python-${VERSION}.tar.xz"
    local url="https://www.python.org/ftp/python/${VERSION}/Python-${VERSION}.tar.xz"

    if [ ! -f "$tarball" ]; then
        echo "  Fetching $url"
        /usr/bin/curl -L -o "$tarball" "$url"
    else
        echo "  Python tarball already in downloads"
    fi

    echo "  Unpacking to $PYTHON_SRC"
    /usr/bin/tar -xf "$tarball" -C "$PYTHON_SRC" --strip-components=1
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


download_openssl() {
    echo
    echo "==== Downloading OpenSSL ===="
    echo

    if [[ "$OPENSSL_VERSION" == "auto" ]]; then
        detect_latest_openssl
    fi

    local tarball="$DOWNLOAD_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
    local url="https://www.openssl.org/source/${tarball##*/}"
    local github_url="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${tarball##*/}"
    local checksum_url="${url}.sha256"

    echo "Downloading OpenSSL source (${OPENSSL_VERSION})..."
    cd "$DOWNLOAD_DIR"

    if [ -f "$tarball" ]; then
        echo "  OpenSSL tarball already present in downloads"
    else
        local curl_official=false
        /usr/bin/curl -L --fail --silent --show-error -o "$tarball" "$url" && curl_official=true

        if $curl_official; then
            echo "  Downloaded from official openssl.org"
        else
            echo "  Official URL failed - falling back to GitHub"
            /usr/bin/curl -L -o "$tarball" "$github_url"
        fi

        local checksum_downloaded=false
        /usr/bin/curl -L --silent --fail -o "${tarball}.sha256" "$checksum_url" && checksum_downloaded=true

        if $checksum_downloaded; then
            echo "  Verifying SHA256 checksum..."
            local checksum_ok=false
            /usr/bin/shasum --algorithm 256 --check "${tarball}.sha256" && checksum_ok=true

            if $checksum_ok; then
                echo "  Checksum verified."
            else
                echo "  Checksum verification FAILED"
                exit 1
            fi
            /bin/rm "${tarball}.sha256"
        else
            echo "  No checksum file available - skipping verification"
        fi
    fi

    # Unpack into flavor-specific openssl-src (next to openssl-build)
    echo "  Unpacking OpenSSL source..."
    local openssl_src_dir="$BUILD_FLAVOR_DIR/openssl-src"
    /bin/rm -rf "$openssl_src_dir"
    /bin/mkdir -pv "$openssl_src_dir"
    /usr/bin/tar xf "$tarball" -C "$openssl_src_dir" --strip-components=1
}

build_openssl() {
    echo
    echo "==== Building OpenSSL ${OPENSSL_VERSION} as shared libs ===="
    echo

    export MACOSX_DEPLOYMENT_TARGET

    cd "$BUILD_FLAVOR_DIR"
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
    for host_arch in "${target_archs[@]}"; do
        local arch_build="${OPENSSL_BUILD}/${host_arch}"
        local arch_install="${OPENSSL_BUILD}/${host_arch}-install"
        /bin/mkdir -pv "$arch_build" "$arch_install"
        per_arch_installs+=("$arch_install")

        cd "$arch_build"

        local config_target
        if [ "$host_arch" = "arm64" ]; then
            config_target="darwin64-arm64-cc"
        else
            config_target="darwin64-x86_64-cc"
        fi

        echo "Configuring OpenSSL for $host_arch (shared)..."
        "$BUILD_FLAVOR_DIR/openssl-src/Configure" $config_target shared no-asm \
            --prefix="$arch_install" --openssldir="$arch_install/ssl"

        /usr/bin/make -j8
        /usr/bin/make install_sw install_ssldirs
        cd "$BUILD_FLAVOR_DIR"
    done

    /bin/cp -R "${per_arch_installs[0]}/"* "$OPENSSL_INSTALL/"

    if [ "$ARCH" = "universal" ]; then
        echo "Creating universal dylibs via lipo..."
        /usr/bin/lipo -create \
            "${per_arch_installs[0]}/lib/libssl.dylib" \
            "${per_arch_installs[1]}/lib/libssl.dylib" \
            -output "$OPENSSL_INSTALL/lib/libssl.dylib"

        /usr/bin/lipo -create \
            "${per_arch_installs[0]}/lib/libcrypto.dylib" \
            "${per_arch_installs[1]}/lib/libcrypto.dylib" \
            -output "$OPENSSL_INSTALL/lib/libcrypto.dylib"
    fi
}

copy_and_relocate_openssl_dylibs() {
    echo
    echo "==== Copying and relocating bundled OpenSSL shared libraries ===="
    echo

    /bin/mkdir -pv "$INSTALL_DIR/lib"
    echo "  Copying libssl.dylib and libcrypto.dylib"
    /bin/cp -v "$OPENSSL_INSTALL/lib/libssl.dylib" "$OPENSSL_INSTALL/lib/libcrypto.dylib" "$INSTALL_DIR/lib/"

    cd "$INSTALL_DIR/lib"
    echo "  Stripping debug symbols from dylibs"
    /usr/bin/strip -x -v libssl.dylib libcrypto.dylib

    echo "  Setting relative install names"
    /usr/bin/install_name_tool -id "@executable_path/../lib/libssl.dylib" libssl.dylib
    /usr/bin/install_name_tool -id "@executable_path/../lib/libcrypto.dylib" libcrypto.dylib

    echo "  Fixing all libcrypto references in libssl.dylib"
    local crypto_refs
    crypto_refs=$( /usr/bin/otool -L libssl.dylib | /usr/bin/awk '/libcrypto/ {print $1}' )
    
    if [ -n "$crypto_refs" ]; then
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

    cd "$PYTHON_SRC"
    /bin/mkdir -pv "$INSTALL_DIR"
    
    # Clean any previous build artifacts that might have wrong architecture
    echo "  Cleaning previous build artifacts..."
    /usr/bin/make distclean 2>/dev/null || true

    local -a flags=(
        --enable-shared
# TEMP DISABLE        --enable-optimizations
        --with-lto
        --prefix="$INSTALL_DIR"
        --with-openssl="$OPENSSL_INSTALL"
        --with-openssl-rpath=auto
    )

    flags+=(MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET})

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

    ./configure "${flags[@]}"

}

build_and_install() {
    echo
    echo "==== Building and installing Python ===="
    echo

    /usr/bin/make -j8
    /usr/bin/make install
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
    /usr/bin/install_name_tool -id "@executable_path/../lib/${lib_name}" "$INSTALL_DIR/$lib_path"

    echo "  Fixing load command in executable $INSTALL_DIR/$exe"
    /usr/bin/install_name_tool -change "$INSTALL_DIR/lib/${lib_name}" \
                               "@executable_path/../lib/${lib_name}" \
                               "$INSTALL_DIR/$exe"
}

relocate_ssl_extensions() {
    echo
    echo "==== Relocating OpenSSL references in _ssl and _hashlib extensions ===="
    echo

    local dynload_dir="$INSTALL_DIR/lib/python${MAJOR_MINOR}/lib-dynload"
    cd "$dynload_dir"

    # Find all potential old OpenSSL paths from the build
    local old_ssl_paths
    old_ssl_paths=$( /usr/bin/find "$OPENSSL_BUILD" -name 'libssl*.dylib' 2>/dev/null | /usr/bin/sort -u )
    
    local old_crypto_paths
    old_crypto_paths=$( /usr/bin/find "$OPENSSL_BUILD" -name 'libcrypto*.dylib' 2>/dev/null | /usr/bin/sort -u )

    if [ -z "$old_ssl_paths" ] && [ -z "$old_crypto_paths" ]; then
        echo "  No build-time OpenSSL dylibs found — nothing to relocate"
        return 0
    fi

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

install_additional_modules() {
    echo
    echo "==== Installing certifi for SSL certificate verification ===="
    echo

    cd "$INSTALL_DIR/bin/"
    ./python${MAJOR_MINOR} -m pip install --verbose certifi --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org
}

deployment_cleanup() {
    echo
    echo "==== Performing deployment cleanup ===="
    echo

    cd "$INSTALL_DIR"

    echo "  Removing include/ and share/man/"
    /bin/rm -rfv include share/man

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

    echo "  Removing precompiled bytecode"
    /usr/bin/find lib/python${MAJOR_MINOR} -type d -name "__pycache__" -exec /bin/rm -rfv {} +
    /usr/bin/find lib/python${MAJOR_MINOR} -name "*.py[co]" -exec /bin/rm -v {} \;
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

rename_build_artifacts() {
    echo
    echo "==== Renaming build flavor directory to: ${BUILD_FLAVOR_DIR}.last ===="
    echo

    if [ -d "${BUILD_FLAVOR_DIR}.last" ]; then
        /bin/rm -rf "${BUILD_FLAVOR_DIR}.last"
    fi
    /bin/mv -v "$BUILD_FLAVOR_DIR" "${BUILD_FLAVOR_DIR}.last"
}

run_tests() {
    echo
    echo "==== Running basic sanity tests on the built Python ===="
    echo

    local test_script="${SCRIPT_DIR}/test_custom_python.py"

    if [ ! -f "$test_script" ]; then
        echo "Warning: Test script not found at $test_script - skipping tests"
        return 0
    fi

    echo "  Executing: $FINAL_DIR/bin/python${MAJOR_MINOR} $test_script"
    set +e
    "$FINAL_DIR/bin/python${MAJOR_MINOR}" "$test_script"
    set -e
    
    if [ "$ARCH" = "universal" ]; then
        local build_arch
        build_arch=$(/usr/bin/uname -m)
        
        if [ "$build_arch" = "arm64" ]; then
            set +e
            local is_rosetta_available=$(/usr/bin/arch -x86_64 /usr/bin/uname -m)
            if [ "$is_rosetta_available" = "x86_64" ]; then
                echo "  Executing Intel code under Rosetta to verify universal binary:"
                echo "  arch --x86_64 $FINAL_DIR/bin/python${MAJOR_MINOR} $test_script"
                /usr/bin/arch --x86_64 "$FINAL_DIR/bin/python${MAJOR_MINOR}" "$test_script"
            fi
            set -e
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
    echo "  1. Install packages: $FINAL_DIR/bin/python${MAJOR_MINOR} -m pip install ..."
    echo "  2. Thin further if needed: ./thin_python_distribution.sh \"$FINAL_DIR\" ..."
    echo "  3. Bundle and test in your app"
    echo
}

main() {
    prepare
    download_python
    download_openssl
    build_openssl
    configure_python
    build_and_install
    make_relocatable
    copy_and_relocate_openssl_dylibs
    relocate_ssl_extensions
    install_additional_modules
    strip_debug_symbols
    deployment_cleanup
    finalize
    rename_build_artifacts
    run_tests
    print_summary
}

main
