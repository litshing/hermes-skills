---
name: hermes-plugin-development
description: Use when extending Hermes with a plugin or context engine.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags:
      - hermes
      - plugins
      - context-engine
      - extension
      - abc
    related_skills:
      - hermes-cron-ops
      - hermes-agent-skill-authoring
---

# Building Hermes Agent Plugins

## When to Use

- The user wants behaviour a skill cannot provide: code that runs *inside* the
  agent loop (compaction, tools, providers, platforms).
- Replacing the built-in context engine / compaction strategy.
- Adding a model provider, platform adapter, memory provider, or tool backend.
- A plugin the user installed "is connected but does nothing".
- Debugging why a plugin's `register()` never seems to run.

## Skill or plugin? Decide first

| Need | Use |
|---|---|
| Instructions/checklists injected into the prompt | **skill** |
| Code invoked inside the agent loop | **plugin** |
| One-off capability with no agent-loop coupling | **CLI command + skill** (cheapest) |

Hermes' own contribution rubric puts it as a ladder: extend existing code → CLI
command + skill → service-gated tool → **plugin** → MCP server → new core tool
(last resort). Reach for a plugin only when the agent loop itself must be
extended.

## Where plugins live — four sources, later wins on name collision

```
1. Bundled   <repo>/plugins/<name>/                  shipped with hermes-agent
2. User      ~/.hermes/plugins/<name>/               ← install yours here
3. Project   ./.hermes/plugins/<name>/               opt-in: HERMES_ENABLE_PROJECT_PLUGINS
4. Pip       entry-point group hermes_agent.plugins
```

The bundled scan deliberately **skips** `memory/` and `context_engine/` subdirs —
those have their own discovery paths.

## Anatomy

```
~/.hermes/plugins/<name>/
├── plugin.yaml     # manifest
└── __init__.py     # must define register(ctx)
```

`plugin.yaml` fields (verified against bundled plugins):

```yaml
name: my-plugin
version: 0.1.0
description: >
  What it does and why it exists. Fold in the failure mode it avoids.
author: Whoever
kind: standalone          # standalone | backend | exclusive | platform | model-provider
requires_env:
  - name: SOME_API_KEY
    description: "What the key is"
    prompt: "Display prompt"
    url: "https://where/to/get/it"
    password: true
```

`kind`: `exclusive` is for memory providers; `backend` for image/video backends;
`platform` for chat adapters; `standalone` is the safe generic default. Leave
the tool-override capability **off** unless the plugin genuinely intercepts
built-in tools.

`__init__.py` registers through the context object passed in:

```python
def register(ctx) -> None:
    ctx.register_context_engine(MyEngine(...))
```

## ⚠️ Three failure modes that make a plugin silently do nothing

These are the ones that cost real time. All three were hit and fixed in one
session; all three look identical from the outside ("installed, no effect").

### 1. Discovery is not activation

Being found in the plugin scan is not the same as being loaded. Until the plugin
is explicitly enabled, `register()` is **never called**:

```
enabled: False
error: 'not enabled in config (run `hermes plugins enable <name>` to activate)'
```

```bash
hermes plugins enable <name>
```

Because `register()` never ran, a getter like `get_plugin_context_engine()`
returns `None` — which reads as "the plugin is broken" when it is merely off.

### 2. The host deep-copies the singleton — locks and handles break it

For context engines the host deep-copies the shared plugin singleton per agent
so one agent's `update_model()` cannot mutate another's:

```python
# agent_init.py, ~#42449
try:
    _selected_engine = copy.deepcopy(_candidate)
except Exception as _copy_err:
    _copy_failed = True
    logger.warning("...could not be safely copied ... falling back to built-in")
    _selected_engine = None
```

A `threading.Lock`, an open DB handle, an HTTP client, or any other uncopyable
member makes this raise — and the plugin is **silently replaced by the built-in**
with only a log line. The fix is to implement `__deepcopy__` and rebuild
locks/caches fresh while deep-copying mutable budget state:

```python
def __deepcopy__(self, memo):
    cls = self.__class__
    new = cls.__new__(cls)
    memo[id(self)] = new
    for key, value in self.__dict__.items():
        if key in ("_lock",):
            setattr(new, key, threading.Lock())
        elif key in ("_cache",):
            setattr(new, key, type(self._cache)())   # fresh cache
        else:
            try:
                setattr(new, key, _copy.deepcopy(value, memo))
            except Exception:
                setattr(new, key, value)             # share, don't lose it
    return new
```

Anything holding a lock, socket, or connection needs this. Test it explicitly —
it is the single easiest way for a plugin to appear installed and do nothing.

### 3. Documented hooks are fail-open, so breakage is invisible

Extension hooks are specified fail-open: a missing hook, a raised exception, or
an invalid return leaves the request untouched, "so a failing engine is never
worse than not installing one". Correct design, terrible for debugging — a
broken plugin behaves exactly like a working one that decides to do nothing.
**Always log on your failure path**, and expose counters through whatever status
method the interface provides.

## Verifying end-to-end WITHOUT a gateway restart

A gateway loads plugins at startup, so a plugin installed after the running
gateway started needs `hermes gateway restart` before it is live. You can still
verify everything up to that point in a throwaway process — this is the cheap
loop to iterate on:

```python
import os, sys
sys.path.insert(0, os.path.expanduser("~/.hermes/hermes-agent"))
os.environ.setdefault("HERMES_HOME", os.path.expanduser("~/.hermes"))

from hermes_cli.plugins import PluginManager, get_plugin_context_engine
mgr = PluginManager()
mgr.discover_and_load()
print(sorted(mgr._plugins))                 # is my plugin discovered?
entry = mgr._plugins.get("my-plugin")
print(entry.enabled, entry.error)           # is it enabled, or failing?
print(get_plugin_context_engine())          # did register() actually run?
```

Then separately import your artifact and exercise it against the real host ABC /
interface. See `scripts/run_plugin_suite.py` for running a plugin's own tests
when its directory name is not a legal Python identifier.

Run this with the **Hermes venv** (`~/.hermes/hermes-agent/venv/bin/python3`) —
the system python3 does not have the agent's dependencies.

## Configuration: the `or default` trap

Reading plugin config with `cfg.get(key) or default` **silently rewrites an
explicit `0`**. That matters because `0` is a meaningful value for several knobs
(protect nothing, keep only the note, never skip a thin batch). A `0` that
becomes the default is a bug that a naive test will miss — and in this session it
turned one test into a **false pass**.

```python
def _cfg_int(cfg, key, default, minimum=None):
    value = cfg.get(key)                 # NOT `or default`
    if value is None:
        return default
    try:
        value = int(value)
    except (TypeError, ValueError):
        return default
    if minimum is not None and value < minimum:
        return default
    return value
```

Treat only missing/`None`/unparseable as "unset". Add a regression test asserting
`_cfg_int({"k": 0}, "k", 20) == 0`.

Related: behavioural settings belong in `config.yaml`, not `.env`. Hermes reserves
`.env` for secrets (API keys, tokens, passwords); a plugin telling users to set a
non-secret env var for behaviour is the wrong shape.

## Cost and blast radius

Plugin hooks may run on **every turn** or every iteration of a tool loop. Before
wiring in anything that calls a paid API, decide the gates and build them in from
the start:

- a minimum batch size (don't spend a request on a trivial case)
- a per-process cooldown between calls
- an in-process memo keyed on the inputs, so unchanged inputs are never re-judged
- a hard per-pass cap on how many items are sent

An engine instance is **shared across sessions** and hooks may be dispatched on a
pooled daemon thread (when `compression.context_timeout_seconds > 0`). Assume no
thread affinity and lock-guard shared state.

## References and scripts

- `references/context-engine-plugins.md` — replacing the built-in
  `ContextCompressor`: the ABC contract, the two-call-site seam, the
  session-persistence contract, and where the selection logic lives.
- `references/jev-system-one-protocol.md` — verified request/response shape for
  TypeSafe's System One (`jev-latest`), a cheap per-item decision primitive.
  Useful whenever a plugin needs many small independent judgements.
- `scripts/run_plugin_suite.py` — run a plugin's `test_*` functions without
  pytest's collector, for plugin dirs whose names contain a hyphen.

## Pitfalls

- **A context engine's prune seam MUST NOT change the row count.** This one took
  a live session down (2026-09-18). `ContextCompressor.compress` captures
  `n_messages = len(messages)` *before* it calls `self._prune_old_tool_results(...)`
  and only recomputes it when it strips platform-echo rows itself. If your
  override returns a **shorter** list, the later tail-assembly loop
  `for i in range(max(compress_end, tail_start), n_messages): ... messages[i]`
  indexes past the end → `IndexError: list index out of range` inside
  `context_compressor.py`, on **every** auto-compression, surfacing to the user as
  "Sorry, I encountered an unexpected error". The built-in prune always returns
  the same length (it copies every row and only rewrites `content`), so the
  contract is invisible until a plugin breaks it.
  - Fix: DROP the *payload*, not the row — keep the `tool` message in place with
    its `tool_call_id` and replace `content` with a one-line note. Keep the
    assistant `tool_calls` entry too, so no result is orphaned. Savings are
    essentially identical (the bulky text is what costs tokens).
  - Nulling the row in place also fixes a second latent bug: index-based writes
    (e.g. `_truncate_results` using `candidate["result_idx"]`) stay valid only
    while the list keeps its shape.
  - Catch it with an A/B proof, not a unit test of your own helper: (a) a stub
    subclass whose prune returns `out[:-5]` must raise `IndexError` from
    `compress`; (b) your real engine, forced to DROP, must complete `compress`
    and return the same input/output row count from the seam. See
    `scripts/run_plugin_suite.py`.
- **Hyphenated plugin directories and pytest.** pytest tries to import
  `<dir>/__init__.py` when its rootdir sits inside the plugin (or the repo root),
  which dies on a relative `from . import jev` with "attempted relative import
  with no known parent package" — every test reports as an ERROR before it runs,
  which reads like a broken plugin. It is a *collection* artifact, not your code:
  run pytest from a neutral cwd with the absolute test path and it collects fine
  (verified: 28 passed from `/tmp`, 28 errors from the repo root). Keep
  `scripts/run_plugin_suite.py` for the runner-without-pytest route.
- **Don't edit core files to add a plugin.** Plugins work within the
  ABCs/hooks provided; if one needs more, widen the generic plugin surface
  rather than special-casing in core. Plugins that touch core files are rejected.
- **A plugin that is "not found" may just be off.** Check the `enabled`/`error`
  fields on the registry entry before reading the source.
- **Verify the config value is set, not just the plugin enabled.** Enabling a
  plugin and selecting it are two separate steps; after enabling, the active
  implementation is unchanged until the selection key points at it.
