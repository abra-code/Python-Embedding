
# test_multiprocessing.py
# Run directly: ./Python-*/bin/python3.14 test_multiprocessing.py
#   Expected output: Multiprocessing result: [1, 4, 9]

# Verifies multiprocessing functionality in a relocatable/shared Python build on macOS.
# Must be run separately from the main test suite due to the need for a proper
# __name__ == '__main__' guard to prevent recursive spawning in 'spawn' mode.
# Non-obvious: Uses 'spawn' start method implicitly (macOS default for relocatable builds).
# Explicit set_start_method('spawn') is optional as Python 3.14 defaults to 'spawn' on macOS
# when running as __main__ in a shared libpython context. The worker function must be
# top-level (picklable) to avoid serialization errors. Safe for embedded use when structured this way.


import multiprocessing

def worker_sq(x):
    return x * x

if __name__ == '__main__':
    # multiprocessing.set_start_method('spawn')  # Optional: macOS defaults to 'spawn' in this context
    with multiprocessing.Pool(2) as p:
        result = p.map(worker_sq, [1, 2, 3])
        print("Multiprocessing result:", result)
