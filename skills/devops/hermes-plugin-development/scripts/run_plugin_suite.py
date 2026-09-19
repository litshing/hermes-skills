#!/usr/bin/env python3
"""Run a Hermes plugin's test suite without pytest's collector.

Why this exists
---------------
A Hermes plugin directory often has a name that is not a legal Python
identifier (e.g. ``jev-compaction``), because the directory name can be
load-bearing — it may have to match a config value the host compares against.
pytest cannot collect tests inside such a directory: it tries to import
``<dir>/__init__.py`` as a package and every test errors with::

    CollectorError: ImportError while importing test module '.../__init__.py'
    ImportError: attempted relative import with no known parent package

Neither ``--import-mode=prepend`` nor ``--import-mode=importlib`` avoids it, and
renaming the plugin to please the collector is the wrong fix.

So: import the plugin and the test module directly, then call every ``test_*``
function with the fixtures it asks for. Fixtures are resolved generically — a
param name matching a non-test function in the test module is called as a
fixture, recursively — plus a built-in ``monkeypatch``.

Usage
-----
    # run with the Hermes venv; it has the agent's dependencies
    ~/.hermes/hermes-agent/venv/bin/python3 scripts/run_plugin_suite.py \\
        ~/.hermes/plugins/jev-compaction

    # explicit test file, or a different repo to put on sys.path
    ... scripts/run_plugin_suite.py <plugin_dir> [test_file] [--repo <path>]

Exit code is 0 only when nothing failed.
"""

from __future__ import annotations

import importlib.util
import inspect
import os
import sys
import time
import traceback

DEFAULT_REPO = os.path.expanduser("~/.hermes/hermes-agent")

_MISSING = object()


# --------------------------------------------------------------------- loading

def load_module(name: str, path: str, package_dir: str | None = None):
    """Import a file by path, optionally as a package so relative imports work."""
    spec = importlib.util.spec_from_file_location(
        name,
        path,
        submodule_search_locations=[package_dir] if package_dir else None,
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def find_test_file(plugin_dir: str) -> str:
    tests_dir = os.path.join(plugin_dir, "tests")
    for root in (tests_dir, plugin_dir):
        if not os.path.isdir(root):
            continue
        for fname in sorted(os.listdir(root)):
            if fname.startswith("test_") and fname.endswith(".py"):
                return os.path.join(root, fname)
    raise SystemExit(f"no test_*.py found under {plugin_dir}/tests or {plugin_dir}")


# ---------------------------------------------------------------- monkeypatch

class MiniMonkeyPatch:
    """The subset of pytest's monkeypatch that plugin tests typically use."""

    def __init__(self):
        self._undo: list = []

    def setattr(self, obj, name, value):
        self._undo.append((obj, name, getattr(obj, name, _MISSING)))
        setattr(obj, name, value)

    def delattr(self, obj, name, raising=True):
        self._undo.append((obj, name, getattr(obj, name, _MISSING)))
        try:
            delattr(obj, name)
        except AttributeError:
            if raising:
                raise

    def setitem(self, mapping, key, value):
        self._undo.append((mapping, key, mapping.get(key, _MISSING)))
        mapping[key] = value

    def delenv(self, name, raising=True):
        self._undo.append((os.environ, name, os.environ.get(name, _MISSING)))
        os.environ.pop(name, None)

    def setenv(self, name, value, prepend=None):
        self._undo.append((os.environ, name, os.environ.get(name, _MISSING)))
        os.environ[name] = str(value)

    def undo(self):
        for obj, name, old in reversed(self._undo):
            if isinstance(obj, dict) or obj is os.environ:
                if old is _MISSING:
                    obj.pop(name, None)
                else:
                    obj[name] = old
            elif old is _MISSING:
                try:
                    delattr(obj, name)
                except AttributeError:
                    pass
            else:
                setattr(obj, name, old)
        self._undo.clear()


# ------------------------------------------------------------------ skipping

def skip_reason(fn) -> str | None:
    """Honour @pytest.mark.skipif so a live/paid test doesn't run by accident."""
    for mark in getattr(fn, "pytestmark", []) or []:
        if getattr(mark, "name", "") != "skipif":
            continue
        args = getattr(mark, "args", ())
        try:
            cond = bool(args[0]) if args else False
        except Exception:
            cond = False
        if cond:
            return getattr(mark, "kwargs", {}).get("reason") or "skipif"
    return None


# ------------------------------------------------------------------ fixtures

def resolve_fixture(name, test_mod, plugin_mod, cache, depth=0):
    """Resolve one fixture by name. Generic: any non-test function works."""
    if name in cache:
        return cache[name]
    if depth > 8:
        raise RuntimeError(f"fixture recursion resolving {name!r}")

    if name == "monkeypatch":
        value = MiniMonkeyPatch()
        cache[name] = value
        return value
    if name in ("mod", "plugin", "plugin_mod"):
        cache[name] = plugin_mod
        return plugin_mod

    fn = getattr(test_mod, name, None)
    if callable(fn) and not name.startswith("test_"):
        kwargs = {
            p: resolve_fixture(p, test_mod, plugin_mod, cache, depth + 1)
            for p in inspect.signature(fn).parameters
        }
        value = fn(**kwargs)
        cache[name] = value
        return value

    raise RuntimeError(
        f"cannot resolve fixture {name!r}: no such function in the test module "
        f"and it is not one of the built-ins (monkeypatch, mod)"
    )


# ---------------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    repo = DEFAULT_REPO
    if "--repo" in argv:
        repo = argv[argv.index("--repo") + 1]
        args = [a for a in args if a != repo]
    if not args:
        print(__doc__)
        return 2

    plugin_dir = os.path.abspath(os.path.expanduser(args[0]))
    test_file = os.path.abspath(os.path.expanduser(args[1])) if len(args) > 1 \
        else find_test_file(plugin_dir)
    if repo and repo not in sys.path:
        sys.path.insert(0, repo)

    started = time.time()
    pkg_name = "plugin_under_test"
    plugin_mod = load_module(pkg_name, os.path.join(plugin_dir, "__init__.py"), plugin_dir)
    test_mod = load_module("plugin_under_test_suite", test_file)

    passed, failed, skipped = [], [], []
    names = sorted(n for n in dir(test_mod) if n.startswith("test_"))
    if not names:
        print(f"no test_* functions found in {test_file}")
        return 2

    for name in names:
        fn = getattr(test_mod, name)
        if not callable(fn):
            continue
        reason = skip_reason(fn)
        if reason:
            skipped.append((name, reason))
            continue

        cache: dict = {}
        mp = None
        try:
            kwargs = {
                p: resolve_fixture(p, test_mod, plugin_mod, cache)
                for p in inspect.signature(fn).parameters
            }
            mp = cache.get("monkeypatch")
            fn(**kwargs)
            passed.append(name)
        except Exception as exc:
            failed.append((
                name,
                "".join(traceback.format_exception_only(type(exc), exc)).strip(),
                traceback.format_exc(),
            ))
        finally:
            if mp is not None:
                mp.undo()

    print("=" * 74)
    for n in passed:
        print(f"  PASS  {n}")
    for n, why in skipped:
        print(f"  SKIP  {n}  ({why})")
    for n, why, _ in failed:
        print(f"  FAIL  {n}\n        {why}")
    print("=" * 74)
    print(f"{len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped "
          f"in {time.time() - started:.2f}s")

    if failed:
        print("\n---- first failure traceback ----")
        print(failed[0][2])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
