# test_custom_python.py
# Sanity checks for embedded/custom Python build.
# Run: /path/to/Python-*/bin/python3.14 test_custom_python.py

import sys
import os
import subprocess

# Use certifi if installed (fixes custom builds with bundled OpenSSL)
try:
    import certifi
    os.environ['SSL_CERT_FILE'] = certifi.where()
except Exception:
    pass

print(f"Python {sys.version.split()[0]} on {sys.platform}")
print(f"Executable: {sys.executable}")
print()

# ANSI colors for terminal
GREEN = "\033[92m"
RED = "\033[91m"
RESET = "\033[0m"

failed_count = 0

def run_test(name, func):
    print(f"=== {name} ===")
    try:
        func()
        print(f"{GREEN}PASS{RESET}")
    except Exception as e:
        failed_count += 1
        print(f"{RED}FAIL: {e}{RESET}")
    print()

def test_basic_imports():
    imports = [
        "json", "datetime", "urllib.request", "http.client",
        "zlib", "gzip", "bz2",
        "sqlite3", "csv", "configparser", "xml.etree.ElementTree",
        "threading", "subprocess", "shutil",
        "re", "collections", "itertools", "functools",
        "math", "random", "statistics", "ctypes", "decimal"
    ]
    for mod in imports:
        __import__(mod)
    print("All basic stdlib modules imported successfully")

def test_sqlite3():
    import sqlite3
    conn = sqlite3.connect(":memory:")
    conn.execute("CREATE TABLE t (x INTEGER)")
    conn.execute("INSERT INTO t VALUES (42)")
    row = conn.execute("SELECT x FROM t").fetchone()[0]
    print("SQLite row value:", row)
    conn.close()

def test_threading():
    import threading
    import time
    def worker():
        time.sleep(0.05)
    t = threading.Thread(target=worker)
    t.start()
    t.join()
    print("Thread started and joined successfully")

def test_compression():
    data = b"test data" * 100
    import zlib, gzip, bz2
    print("zlib compressed len:", len(zlib.compress(data)))
    print("gzip compressed len:", len(gzip.compress(data)))
    print("bz2 compressed len:", len(bz2.compress(data)))

def test_json():
    import json
    obj = {"unicode": "żółw", "num": 3.14, "list": [1, 2, 3]}
    serialized = json.dumps(obj)
    deserialized = json.loads(serialized)
    print("JSON round-trip unicode:", deserialized["unicode"])

def test_ctypes():
    import ctypes
    libc = ctypes.CDLL(None)  # load libc (dyld on macOS)
    print("Loaded libc time():", libc.time(None))

def test_decimal():
    from decimal import Decimal
    a = Decimal('3.1415926535')
    b = a * Decimal('2')
    print("Decimal precision:", b)

def test_hashlib():
    import hashlib
    print("SHA3-256:", hashlib.sha3_256(b"test").hexdigest()[:16])
    print("BLAKE2b:", hashlib.blake2b(b"test").hexdigest()[:16])

def test_ssl():
    import ssl
    ctx = ssl.create_default_context()
    print("SSL context created successfully")
    print("Default protocols:", ssl.OP_NO_SSLv2 | ssl.OP_NO_SSLv3 | ssl.OP_NO_TLSv1)  # just to show constants

def test_ssl_https():
    import ssl
    import urllib.request
    ctx = ssl.create_default_context()
    with urllib.request.urlopen("https://www.python.org", context=ctx, timeout=10) as r:
        data = r.read(100)
        print(f"HTTPS OK (status {r.status}, received {len(data)} bytes)")

def test_multiprocessing():
    # Run separate test_multiprocessing.py to ensure proper __main__ guard
    script_path = os.path.join(os.path.dirname(__file__), "test_multiprocessing.py")
    result = subprocess.run(
        [sys.executable, script_path],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0:
        print(result.stdout.strip())
    else:
        raise RuntimeError(f"Multiprocessing test failed:\n{result.stderr}")

# Run tests
run_test("Basic stdlib imports", test_basic_imports)
run_test("SQLite3", test_sqlite3)
run_test("Threading", test_threading)
run_test("Multiprocessing", test_multiprocessing)
run_test("Compression (zlib/gzip/bz2)", test_compression)
run_test("JSON round-trip", test_json)
run_test("ctypes (libc load)", test_ctypes)
run_test("Decimal precision", test_decimal)
run_test("Hashlib modern algorithms", test_hashlib)
run_test("Basic ssl", test_ssl)
run_test("ssl + HTTPS fetch", test_ssl_https)

if failed_count > 0:
    print(f"{RED}\n{failed_count} test(s) failed.{RESET}\n")
    sys.exit(1)
else:
    print(f"{GREEN}All tests passed.{RESET}\n")
