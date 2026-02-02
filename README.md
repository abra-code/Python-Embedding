# Python Embedding for macOS
Build a minimal, relocatable deployment-only Python runtime for embedding in macOS apps<br>

Main script: `build-embedded-python.sh`<br>
  - builds universal binaries from the latest version of Python with latest version of OpenSSL when invoked without any arguments:
    `./build-embedded-python.sh`
  - you may specify --arch=arm64 for single-architecture binary for Apple Silicon Macs only
  - the latest version is automatically detected and downloaded but you may specify a different Python version with --version=3.x.x
  - cross-compilation of single architecture is not supported by Python build system, i.e. you cannot build x86_64 on arm64 Mac but you can build universal binary with both architectures
  - tests scripts are run after a successful build and can also be executed separately<br>
<br>
Additional scripts:<br>
  - `install_modules.sh`: Installs additional Python modules into a relocatable Python distribution
    Usage: `./install_modules.sh --python-dir=/path/to/Python-3.x.x-universal module1 module2`
  - `thin_python_distribution.sh`: Removes optional components to reduce distribution size
    Usage: `./thin_python_distribution.sh [--arch arm64|x86_64] /path/to/Python [component1 component2 ...]`<br>
    Components: ssl, hashlib, sqlite3, curses, xml, dbm, decimal, ctypes, multiprocessing, unittest, pip, pyc, etc.
<br>
