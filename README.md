# Python Embedding for macOS
Build a minimal, relocatable deployment-only Python runtime for embedding in macOS apps<br>

Main script: `build-embedded-python.sh`<br>
  - builds universal binaries from the latest version of Python with latest version of OpenSSL when invoked without any arguments:
    `./build-embedded-python.sh`
  - you may specify --arch=arm64 for single-architecture binary for Apple Silicon Macs only
  - the latest version is automatically detected and downloaded but you may specify a different Python version with --version=3.x.x
  - cross-compilation of single architecture is not supported by Python build system, i.e. you cannot build x86_64 on arm64 Mac but you can build universal binary with both architectures
<br>
Further customization and thinning of optional/unused extensions and modules is possible with `thin_python_distribution.sh` script<br>
Tests scripts are run after a successful build and can also be executed separately<br>
