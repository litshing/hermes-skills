# Implementing a Hermes context-engine plugin — code-level notes

Everything here was read out of the shipping source in `~/.hermes/hermes-agent`
(or reproduced in code). File:line pointers are from the checkout at the time of
writing; re-grep if they drift.

## File:line index

| What | Where |
|---|---|
| `ContextEngine` ABC | `agent/context_engine.py` (~490 lines) |
| Built-in `ContextCompressor` | `agent/context_compressor.py` (~7860 lines) |
| Engine selection + construction | `agent/agent_init.py` ~2500–2660 |
| Plugin loader / sources / kinds | `hermes_cli/plugins.py` |
| Official plugin guide | `website/docs/developer-guide/context-engine-plugin.md` |
| ABC contract tests | `tests/agent/test_context_engine.py` (347 lines) |
| Plugin-engine regression test | `tests/gateway/test_compress_plugin_engine.py` |
| Host contract test | `tests/agent/test_context_engine_host_contract.py` |

## ⚠️ The deepcopy trap — a silent-failure mode

`agent/agent_init.py` deep-copies the shared plugin engine **per agent** so one
agent's `update_model()` cannot mutate another's:

```python
# agent_init.py, plugin-engine branch
_candidate = get_plugin_context_engine()          # the singleton from register(ctx)
if _candidate is not None and _candidate.name == _engine_name:
    import copy
    try:
        _selected_engine = copy.deepcopy(_candidate)
    except Exception as _copy_err:
        _copy_failed = True
        logger.warning("Context engine '%s' could not be safely copied ... "
                       "falling back to built-in compressor.", ...)
        _selected_engine = None
```

If `__deepcopy__` raises, the host **silently falls back to the built-in
compressor**. The user sees `context.engine: my-engine` in config, no error in
normal operation, and the engine doing absolutely nothing. A `threading.Lock`
(and anything else unpicklable — DB handles, open clients) will raise.

The host comment names the remedy: engines holding uncopyable state "should
implement `__deepcopy__` to copy only mutable budget state."

```python
def __deepcopy__(self, memo):
    cls = self.__class__
    new = cls.__new__(cls)
    memo[id(self)] = new
    for key, value in self.__dict__.items():
        if key == "_lock":
            setattr(new, key, threading.Lock())      # rebuild, never copy
        elif key == "_cache":
            setattr(new, key, SomeCache())
        else:
            try:
                setattr(new, key, copy.deepcopy(value, memo))
            except Exception:
                setattr(new, key, value)             # share rather than lose it
    return new
```

Any engine that does cost-bearing or request-bearing work must hold a lock
(thread-safety contract below), so **this trap applies to essentially every real
engine.** Make `copy.deepcopy(engine)` an explicit unit test.

## Subclass `ContextCompressor` — don't hold an inner instance

The "hold an inner compressor and forward" shape is workable but loses free
machinery. Subclassing inherits:

- `archive_and_compact()` session-DB commit + `_DB_PERSISTED_MARKER` stamping
- the prompt-cache re-arm runway (`_proactive_prune_rearm_tokens`, persisted in
  the session row's `model_config` so it survives restarts)
- the capability gate for duck-typed/plugin session stores that lack
  `archive_and_compact` (without it every prune is a permanent silent no-op)
- byte-identical-result dedup (pass 1 — lossless, tail-agnostic by design)
- all ABC-required methods, so the ABC is satisfied for free
- micro-compaction wiring the host applies by `hasattr` after construction

Subclass, override only your seam, and the ABC + persistence contracts come along.

## The seam: `_prune_old_tool_results()`

It is called from **two** places, so one override covers both the cheap
proactive-prune path and the full-compression path:

- `prune_tool_results_only()` (~line 3754) — the LLM-free, low-trigger path
- `compress()` (~line 6990) — the full compaction path

Signature and the pattern that reuses everything above it:

```python
def _prune_old_tool_results(self, messages, protect_tail_count,
                            protect_tail_tokens=None, min_prune_chars=_PRUNE_MIN_CHARS):
    pre, mine = self._my_prepass(messages, protect_tail_count)   # your judgement
    out, pruned = super()._prune_old_tool_results(
        pre, protect_tail_count, protect_tail_tokens, min_prune_chars)
    return out, pruned + mine      # add your count or the caller sees "no change"
```

Inside the inherited implementation, the built-in clears a result when
`len(content) > min_prune_chars` — **size, not need**. Pass 2 iterates every old
message and calls a local `_demote_tool_result_at(idx)`. That size test is the
exact thing a judgment engine improves on; there is no finer hook, so do your
selective rewrite *before* calling `super()`.

## Object-identity no-op contract

`prune_tool_results_only()` documents that callers gate bookkeeping on
`result is not input`:

> *"Below either gate the INPUT list object is returned unchanged — the standard
> no-op caller contract (callers gate bookkeeping on `result is not input`)."*

So return the **same list object** when you changed nothing. Returning an equal
but distinct list makes the caller believe a cache-breaking rewrite happened.

## Ghost-skill protection (#32106)

Do not drop a `skill_view` tool result wholesale. The transcript would lose the
skill body while the model still believes its instructions are in context. The
built-in defends this via `_collect_protected_skill_names()` and a
`spare_protected_skills` flag. A custom engine making drop decisions must exclude
those candidates up front:

```python
NEVER_DROP_TOOLS = frozenset({"skill_view"})
candidates = [c for c in candidates if c["name"] not in NEVER_DROP_TOOLS]
```

## Message shapes to expect

```python
{"role": "assistant", "content": "", "tool_calls": [
    {"id": "call_x", "type": "function",
     "function": {"name": "read_file", "arguments": '{"path": "src/a.ts"}'}}]}
{"role": "tool", "tool_call_id": "call_x", "content": "…"}
```

Pair by `tool_calls[].id` ↔ `tool_call_id`. Invariants your rewrite must preserve:

- a result never survives its call, and a call never survives without its result —
  they go together on drop;
- an assistant message that loses its last tool call **and** had no text is removed,
  so no empty message reaches the provider;
- multimodal tool content (a `list`, or a `{"_multimodal": True, ...}` dict) cannot
  be deduped or truncate-by-string — handle dict/list shapes explicitly or skip them.

## Fail-open skeleton

The ABC contract is fail-open: any exception leaves the request untouched. That
means **your failures are silent** — log them or nobody will ever know.

```python
def _my_prepass(self, messages, protect_tail_count):
    if not cfg.get("enabled", True) or not messages:
        return messages, 0
    try:
        return self._my_prepass_inner(messages, protect_tail_count, cfg)
    except Exception as exc:
        self._stats["errors"] += 1
        logger.warning("engine pre-pass failed, deferring to built-in: %s", exc)
        return messages, 0
```

Test it: assert the engine returns the *same object* with no exception when the
key is missing and when the transport raises.

## Cost guards (any engine that spends money per pass)

`prune_tool_results_only()` can fire on every iteration of a busy tool loop. A
per-pass request with no guards turns a cheap optimization into a meter.

- `min_candidates` — skip the request entirely for a thin batch; a call has a floor cost.
- cooldown (`min_seconds_between_calls`) — suppress a second request in the same window.
- in-process decision cache keyed on (tool name, args head, result length) — an
  unchanged pair must never be judged twice.
- `max_calls_per_pass` — cap the fan-out.
- Protects the recent tail by *message count*, not by a token budget: the built-in
  notes a token-based tail derived from the 50% compression threshold would protect
  the entire session on a large window and prune nothing.

Thread-safety: `compress()` may run on a pooled daemon thread under a host timeout
(`compression.context_timeout_seconds`, default 120), and passes for different
sessions can run concurrently. Guard the cooldown/cache with a lock, and rebuild
locks in `__deepcopy__`.

## Valid `plugin.yaml` kinds

`hermes_cli/plugins.py`: `_VALID_PLUGIN_KINDS = {"standalone", "backend",
"exclusive", "platform", "model-provider"}`. `exclusive` is what memory providers
use; a context engine is not a memory provider. Manifest keys seen in bundled
plugins: `name`, `version`, `description`, `author`, `kind`, `label`,
`requires_env` (list of bare names or `{name, description, prompt, url, password}`),
`optional_env`, `userConfig`.

## Running the tests — the venv matters

Hermes's interpreter is `~/.hermes/hermes-agent/venv/bin/python3` (3.11.x at the
time of writing), and `agent` is only importable from there with the repo on the
path. Run pytest **through that interpreter**:

```bash
cd ~/.hermes/hermes-agent
venv/bin/python3 -m pytest tests/agent/test_context_engine.py -v
```

If pytest is missing from that venv, check the blast radius before touching it —
it is the runtime the gateway uses:

```bash
uv pip install --python venv/bin/python3 --dry-run pytest   # see what would change
```

Prefer that dry-run over blindly installing. `uv pip install --target DIR pytest`
plus `PYTHONPATH=DIR` avoids modifying the venv at all, at the cost of the target
dir shadowing same-named deps (check for `packaging`/`pygments` overlap).

Loading a plugin from a **hyphenated** directory (`jev-compaction`) cannot use a
normal import. Mirror the loader:

```python
spec = importlib.util.spec_from_file_location(
    "my_mod", os.path.join(PLUGIN_DIR, "__init__.py"),
    submodule_search_locations=[PLUGIN_DIR])   # makes `from . import helper` work
mod = importlib.util.module_from_spec(spec)
sys.modules["my_mod"] = mod
spec.loader.exec_module(mod)
```

## Related docs in the checkout

- `website/docs/developer-guide/context-engine-plugin.md` — the authoritative guide
  (directory layout, required/optional methods, engine tools, thread safety)
- `website/docs/developer-guide/context-compression-and-caching.md` — how the
  built-in compressor works
- `AGENTS.md` — the project's design intent. Relevant here: prompt caching is an
  invariant; per-conversation prompt caching is why `compress()` is the *only*
  sanctioned mid-conversation mutation.
