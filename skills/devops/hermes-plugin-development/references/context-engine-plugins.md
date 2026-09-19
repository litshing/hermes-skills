# Context Engine Plugins (replacing the built-in `ContextCompressor`)

Hermes exposes compaction as a first-class plugin surface. This is a sanctioned
extension point, not a hack. Source of truth:

- ABC: `agent/context_engine.py` (`ContextEngine`)
- Default engine: `agent/context_compressor.py` (`ContextCompressor`)
- Selection: `agent/agent_init.py`, section "Select context engine"
- Docs: `website/docs/developer-guide/context-engine-plugin.md`
- ABC contract tests: `tests/agent/test_context_engine.py`
- Host contract tests: `tests/agent/test_context_engine_host_contract.py`

## Selection order (`agent_init.py`)

```
0. read config.yaml → context.engine   (default "compressor")
1. if not "compressor": plugins/context_engine/<name>/  → load_context_engine(name)
2. else/if not found:   general plugin system → get_plugin_context_engine()
                        (accepted only when engine.name == configured name)
3. else:                warn "not found — falling back to built-in compressor"
4. else:                built-in ContextCompressor
```

Plugin engines are **never auto-activated** — `context.engine` must name one
explicitly. Only **one** engine is active; a second `register_context_engine()`
is rejected with a warning.

Two consequences worth internalising:

- After the plugin is selected, the host resolves `context_length`, assigns
  `model_thresholds`, and calls `update_model()` — so your engine must tolerate
  being constructed with only a model name (or none) and configured later.
- The host deep-copies the singleton per agent (see the main SKILL.md). A
  `__deepcopy__` is effectively mandatory for any engine holding a lock, cache,
  socket, or DB handle.

## Required surface

Subclassing `ContextCompressor` satisfies the ABC for free and is usually the
right move — see "Subclass or implement" below. Implementing from scratch means
providing at minimum:

```python
class MyEngine(ContextEngine):
    @property
    def name(self) -> str: ...            # must equal the context.engine value

    def update_from_response(self, usage: dict) -> None: ...
    def should_compress(self, prompt_tokens: int = None) -> bool: ...
    def compress(self, messages: list, current_tokens=None,
                 focus_topic=None, force=False, memory_context="") -> list: ...
```

Plus these class attributes, which the host reads directly:

```python
last_prompt_tokens = last_completion_tokens = last_total_tokens = 0
threshold_tokens = context_length = compression_count = 0
threshold_percent = 0.75      # when should_compress fires
protect_first_n = 3           # non-system head messages, always verbatim
protect_last_n = 6
emit_automatic_compaction_status = True   # False = routine passes stay silent
```

Optional hooks (all have safe defaults; override only what you need):

| Method | Default | Override when |
|---|---|---|
| `should_compress_info()` | `(should_compress(), None)` | you have a block reason to surface |
| `should_compress_preflight(messages)` | `False` | you can estimate cheaply pre-call |
| `has_content_to_compress(messages)` | `True` | `/compress` preflight guard |
| `prune_tool_results_only(messages, current_tokens)` | no-op `(messages, 0)` | cheap deterministic reclaim |
| `select_context(...)` | `None` (no-op) | you *replace* the per-request context |
| `on_turn_complete(messages, usage, **kw)` | no-op | post-turn observation |
| `on_session_start/end/reset()` | counters reset | you hold per-session state |
| `update_model(...)` | sets `context_length` + threshold | you budget something else |
| `get_tool_schemas()` / `handle_tool_call()` | `[]` / error JSON | your engine exposes agent-callable tools |
| `get_status()` | token/threshold dict | you have custom metrics |

`select_context()` semantics worth knowing: it is **request-only** (persisted
history is untouched) and it is the only hook that may *replace* the message
list. It runs before cache-control and every request sanitizer. Returning the
same/equal list when nothing changed is required — a per-turn reshuffle forfeits
prompt-cache reuse on every turn. If you only need *observation*, the docs say to
implement a memory provider (`sync_turn()`) instead of a context engine.

## The two-call-site seam

If your goal is "change which old tool output gets cleared", you do **not** need
to override `compress()`. In `ContextCompressor`:

```
_prune_old_tool_results(messages, protect_tail_count, protect_tail_tokens=None,
                        min_prune_chars=_PRUNE_MIN_CHARS)
```

is called from **two** places — the cheap proactive-prune path
(`prune_tool_results_only`) and the full-compression path (inside `compress`).
One override there covers both, and you inherit the built-in's three
deterministic passes for free.

What the built-in passes actually do:

1. **Dedup** byte-identical tool results, back-referencing older copies
   (lossless; tail-agnostic).
2. **Demote** non-tail tool results over `min_prune_chars` to a one-line summary.
   Selection here is **by size**, blind to whether the content still matters —
   that blindness is the gap a smarter engine fills.
3. **Truncate** oversized `tool_calls` arguments on non-tail assistant messages
   (valid JSON preserved, otherwise providers 400 forever after).
4. A protected-tail **pressure** pass when the tail itself blows its soft budget.

The safe composition is a pre-pass, not a rewrite:

```python
def _prune_old_tool_results(self, messages, protect_tail_count,
                            protect_tail_tokens=None,
                            min_prune_chars=_PRUNE_MIN_CHARS):
    pre, my_changes = self._prepass(messages, protect_tail_count)
    out, pruned = super()._prune_old_tool_results(
        pre, protect_tail_count, protect_tail_tokens, min_prune_chars)
    return out, pruned + my_changes          # add your count, don't replace it
```

Adding your count matters: the caller short-circuits on `if not pruned_count`.

## `prune_tool_results_only` — read the contract before touching it

This is not a free-form hook. It is gated and it **persists**:

- Gated on `self.proactive_prune_tokens > 0` (0 = disabled) and on
  `current_tokens >= proactive_prune_tokens`.
- Needs messages beyond `protect_last_n + _protect_head_size(messages) + 1`.
- Re-arms via `_proactive_prune_rearm_tokens`: after a commit, it waits until
  history regrows a full trigger-sized runway. Every commit rewrites messages the
  provider already saw, so it invalidates the prompt-cache prefix from the
  earliest rewritten message forward — the reclaim gate plus the re-arm is what
  makes fires episodic instead of per-turn.
- Commits through `session_db.archive_and_compact(session_id, pruned_msgs,
  model_config_patch={...})` and tags survivors with `_DB_PERSISTED_MARKER`.
  **If that call fails it returns the original list** — the DB is the source of
  truth, not the in-memory list.
- Capability gate: a session store without `archive_and_compact` makes every
  prune a permanent no-op, so it bails before the expensive scan.
- **Returns the INPUT object** when disabled/below-trigger/gate-rejected. Callers
  test `result is not input` for bookkeeping — never return a copy on a no-op.

Implication: if you want smarter selection, do it *in front of* this machinery
(the seam above) rather than reimplementing it. Reimplementing means owning the
persistence round-trip, the re-arm hysteresis, and the no-op identity contract —
all of which are covered by existing tests you would then have to satisfy from
scratch.

## Subclass or implement from scratch?

Subclass `ContextCompressor` when you are **improving** compaction. You inherit:
the DB persistence path, the re-arm hysteresis, the dedup pass, the ghost-skill
defense, the pressure pass, and every ABC method. Override one seam.

Implement the ABC directly when you are **replacing** the strategy entirely
(e.g. a DAG-based lossless engine). Then you own compaction policy — note the
host drops its threshold-autoraise notice for external engines because the host
compression threshold never reaches them.

## Ghost-skill defense (#32106)

Skills loaded moments before a compaction must keep their full `skill_view`
bodies through the prune passes. Without this, a skill is demoted to metadata
while the model still believes its instructions are in context. The built-in
enforces it via `_collect_protected_skill_names`; the pressure pass deliberately
overrides it when the tail itself is over budget. **Any custom drop logic must
carry the same guard** — never remove a `skill_view` result wholesale.

## Message invariants a custom rewrite must preserve

Verified by test, all of them break the provider if violated:

- a tool result is never left without its call, and vice versa — both go
  together;
- an assistant message that loses its last tool call **and** has no text is
  removed, so no empty message is sent;
- strict role alternation survives (never two same-role messages in a row);
- message content that is not a plain string (multimodal envelopes, image parts)
  must be handled or skipped, never stringified blindly;
- prompt-cache stability: whatever you return on a no-op must be byte-identical.

## Testing

```bash
cd ~/.hermes/hermes-agent
venv/bin/python3 -m pytest tests/agent/test_context_engine.py -q
venv/bin/python3 -m pytest tests/agent/test_context_engine_host_contract.py -q
```

The host contract suite is the closest thing to an acceptance test, but it tests
the built-in implementation — do not expect it to exercise a plugin engine
directly. Point your own suite at the ABC assertions it encodes.

Run tests with the Hermes venv. If pytest is absent there, install it into the
venv (it pulls only `iniconfig`, `pluggy`, `pytest` — no conflicts observed).
For plugins whose directory name contains a hyphen, pytest cannot collect them at
all; use `scripts/run_plugin_suite.py`.
