# Python Embedding for macOS
Build a minimal, relocatable deployment-only Python runtime for embedding in macOS apps  

Main script: `build-embedded-python.sh`  
  - builds universal binaries from the latest version of Python with latest version of OpenSSL when invoked without any arguments:
    `./build-embedded-python.sh`
  - you may specify --arch=arm64 for single-architecture binary for Apple Silicon Macs only
  - the latest version is automatically detected and downloaded but you may specify a different Python version with --version=3.x.x
  - cross-compilation of single architecture is not supported by Python build system, i.e. you cannot build x86_64 on arm64 Mac but you can build universal binary with both architectures
  - tests scripts are run after a successful build and can also be executed separately
  
Additional scripts:  
  - `install_modules.sh`: Installs additional Python modules into a relocatable Python distribution  
    Usage: `./install_modules.sh --python-dir=/path/to/Python-3.x.x-universal module1 module2`
  - `thin_python_distribution.sh`: Removes optional components to reduce distribution size
    Usage: `./thin_python_distribution.sh [--arch arm64|x86_64] /path/to/Python [component1 component2 ...]`  
    Components: ssl, hashlib, sqlite3, curses, xml, dbm, decimal, ctypes, multiprocessing, unittest, pip, pyc, etc.

  - `analyze_python_deps.py`: Computes the precise module **closure** an app's code needs, so you can see exactly what is dead weight instead of guessing. With `--print plan` it emits a committable JSON **thinning plan**; with `--plan` + `--verify` it resolves/verifies an existing plan.
  - `thin_with_plan.sh`: Applies a committed thinning plan (resolve names, delete, verify), so the plan can be reviewed, tweaked, committed next to the app, and **re-applied** after a Python reinstall wipes the thinned dist.
  - `thin_with_closure.sh`: One-shot convenience that plans and applies in a single command (a thin wrapper over the two above).

These three are **app-agnostic**: you tell them where the interpreter, the entry-point scripts and the third-party deps live (`--python`, `--auto-trace-scripts`, `--packages`, `--root`). They assume no directory layout of their own, so the same tooling thins a Python embedded in any host.

## Closure-based thinning (recommended)

`thin_python_distribution.sh` is a *blacklist*: you name what to remove. That is fragile - one lazily-imported module you forgot and the app ships broken; and it cannot see dependencies pulled in across a `subprocess` boundary (an app that shells out to a bundled console script looks like it imports almost nothing).

The closure tools invert this into a *whitelist + verify* workflow:

1. **Find what the code needs.** `analyze_python_deps.py` collects the modules the app's entry points import, transitively, including C extensions - see the two modes below. (Static `modulefinder` analysis is offered too, but only as a coverage cross-check: it follows imports in dead branches and so over-keeps almost the whole stdlib.)
2. **Delete the complement.** Everything not in the closure is removed. The risk inverts from "did I forget to remove X" to "did I forget to keep Y" - which step 3 catches immediately.
3. **Verify.** The closure is re-established against the thinned interpreter; a module that went missing triggers an automatic restore from backup and a non-zero exit, naming it.

### Two ways to establish the closure

**`--auto-trace-scripts DIR` (recommended, no workload to write).** Every `.py` in `DIR` is an entry point. Each is AST-scanned for the imports it names at any depth and those are imported directly, so **no app code is executed**. This needs nothing hand-written and does not drift as the app changes.

**`--trace CMD` (when a real command must run).** Runs your command under `python -X importtime` and records every module that loads, including inside spawned console scripts. **Coverage is the one rule here:** pass a `--trace` for every distinct path your app runs. Untraced paths are not protected - and unlike the scan, a trace only sees the branches it took.

Either way, conditional imports found in the modules that loaded are made unconditional and traced too, iterated to a fixpoint. Whether a branch fires is not something a dependency scan should decide, and without this the closure misses lazily-imported modules such as `_colorize` (imported inside a function in 3.14's argparse) or `_hashlib`.

```bash
# Point these at your own app's layout:
PY=/path/to/MyApp/embedded/Python           # the distribution to thin
SCRIPTS=/path/to/MyApp/entry-point-scripts  # a dir of .py entry points
ROOT=/path/to/MyApp                         # everything above lives under here

# Inspect what is removable. No change to the distribution - but module-level code of
# everything the scripts import DOES run, so confine it (see Isolation below).
"$PY/bin/python3" analyze_python_deps.py --python "$PY" \
    --auto-trace-scripts "$SCRIPTS" --root "$ROOT" --check-isolation \
    --sandbox-profile trace.sb --scratch /tmp/thin-scratch

# Thin + verify (run after building the app; a rebuild restores the full Python).
# --dry-run first to preview; add --arch arm64 to also slice universal binaries.
./thin_with_closure.sh --python "$PY" \
    --auto-trace-scripts "$SCRIPTS" --root "$ROOT" \
    [--keep name,name] [--arch arm64|x86_64] [--dry-run]
```

Example result (an app embedding the `watchdog` package, already trimmed by a hand-written blacklist to 28.8 MB): closure thinning took it to 19.3 MB, and `--arch arm64` to 11.8 MB - the tool correctly kept the `watchdog` package and its `_watchdog_fsevents` C extension (reached only across a `watchmedo` subprocess) while removing 124 stdlib modules the blacklist had left behind. Across five larger apps, planned with no arguments beyond the paths above: 69.5 -> 42.6 MB, 56.5 -> 38.0 MB, 61.0 -> 38.0 MB, 108.2 -> 87.0 MB, 47.5 -> 28.9 MB.

Some modules cannot be discovered by any of this, because their name does not exist until runtime: `sysconfig` imports its data module via `importlib.import_module(_get_sysconfigdata_name())`, and a codec is looked up by a computed string, which is how the CJK codecs and IDNA reach top-level modules no import statement names. The analyzer asks the interpreter for both sets and force-keeps them (about 2.2 MB). Note what this implies about verification generally: a green run means the recorded workload survived, not that the interpreter is whole - a missing codec surfaces as `LookupError`, which no missing-module check would ever match.

### Isolation

Module-level code of the imported modules runs even in the scan mode, so the analyzer confines it. The traced interpreter's environment is scrubbed of `PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, `PYTHONUSERBASE` and every `DYLD_*` variable, so it cannot load Python or dylibs from outside the tree; `--check-isolation` asserts that every `sys.path` entry lies under `--root` before anything is traced, rather than assuming it. Pass `--sandbox-profile FILE` (and `--scratch DIR`) to run every traced subprocess under `sandbox-exec`. Writing the profile is left to the caller, because what needs confining depends on where the app keeps things.

If the app can be copied cheaply, clone it first and point the analyzer at the copy: then nothing in the real app is ever executed.

### Third-party dependencies

`--packages DIR` points at a deps tree that is on the app's path but is not part of the interpreter. Its **source is scanned like the app's own code**: every import named anywhere in the tree, at any depth, is treated as a dependency, because which files of a distribution load is as much a branch decision as which imports inside a file fire. Without this, modules reachable only from an unexercised package path get removed - measured at 14 names on one app, including `uuid`, `configparser` and `zoneinfo`. `entry_points.txt` is read too, since a plugin loaded by name from metadata has no import statement anywhere. `--no-packages-surface` disables it.

The tree itself is **audited, never thinned**. Trace reachability is the wrong test there: a distribution can be a genuine dependency and still not load during a build-time analysis (TLS, auth and timezone paths typically do not). Each entry is classified by the installed `Requires-Dist` graph - `imported`, `required-by-installed-dist`, `mentioned-in-app-code`, `has-console-script`, `unknown-provenance`, `orphan-candidate` - and the report is always emitted so it surfaces even when it is noise. `packages.remove` is written empty; only a human fills it in.

`--scan-app-code DIR` reads (never runs) shell scripts, configs and plists for `python -m NAME` launches and for uses of the deps' top-level names, comments stripped first. That is what finds an out-of-process entry point nobody declared. Exclude the deps tree and the interpreter from the scan, or every name looks used.

### Persisted plan: separate the "what" from the "do" (plan / apply)

`thin_with_closure.sh` discards its plan after running. For a real app you usually want to **commit the plan** next to the repo so it is reviewable, tweakable, and repeatable - in particular so you can re-thin after a build step replaces the embedded Python with a fresh, fat distribution. Split it into two phases:

```bash
# 1) PLAN: compute the closure and write a committable JSON plan.
"$PY/bin/python3" analyze_python_deps.py --python "$PY" \
    --auto-trace-scripts "$SCRIPTS" --root "$ROOT" --arch arm64 \
    --print plan > MyApp.thinning-plan.json      # review / tweak remove.modules, then commit

# 2) APPLY: perform the removal recorded in the plan, then verify.
./thin_with_plan.sh --python "$PY" --plan MyApp.thinning-plan.json   # [--dry-run] [--skip-verify]
```

The plan records module **names** (not paths) plus the chosen options (`arch`, `include/`, bytecode, orphaned crypto dylibs) and the trace provenance. `apply` resolves those names against the *current* distribution, so the same committed plan re-thins a freshly reinstalled Python correctly. Deleting a name that is no longer present is a harmless no-op; a *new* Python version may ship modules the old plan does not mention (they are simply kept - re-plan to trim them).

**Verification** re-establishes the plan's closure under the just-thinned interpreter using Python's own subprocess timeouts (it does **not** depend on a `timeout` binary, which macOS lacks). A removed-but-needed module - or any workload that crashes - triggers an automatic restore from backup and a non-zero exit. It is driven by a full interpreter (the backup), because the thinned one may itself have lost `json`/`argparse`. Verification demands positive evidence that the interpreter actually ran: a process that imported nothing is a failure, not a pass, however quiet its stderr.

If a plan's workload is a set of entry-point scripts, they have to be re-run somewhere staged, and only the caller knows how to stage them. `thin_with_plan.sh --verify-prepare CMD` runs `CMD` after the deletions and appends whatever it prints on stdout to the verification arguments (typically `--python`, `--root`, `--sandbox-profile`, `--scratch`). If the hook fails, the apply aborts and restores. Without the hook, verification runs in place.

