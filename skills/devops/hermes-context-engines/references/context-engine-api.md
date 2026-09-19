# Context engine API — exact surface and reference detail

Distilled from a live Hermes checkout (macOS, 2026-09). File paths are relative to
`~/.hermes/hermes-agent/`.

## File and doc map

| Path | What it is |
|---|---|
| `agent/context_engine.py` | The `ContextEngine` ABC (~490 lines). **The authoritative interface.** |
| `agent/context_compressor.py` | Built-in default engine (`name == "compressor"`) |
| `agent/conversation_compression.py` | Compression driver / watermark logic |
| `hermes_cli/plugins.py` | Plugin loader; docstring lists the four plugin sources |
| `plugins/context_engine/__init__.py` | Bundled discovery harness exposing `register_context_engine` |
| `tests/agent/test_context_engine.py` | **ABC contract test suite (~347 lines) — use as acceptance test** |
| `tests/gateway/test_compress_plugin_engine.py` | Regression test for the plugin-engine `/compress` bug |
| `toolsets.py` | Defines the `context_engine` toolset gate |
| `website/docs/developer-guide/context-engine-plugin.md` | Official how-to (272 lines) |
| `website/docs/developer-guide/context-compression-and-caching.md` | How the built-in works |

## Required interface

```python
from agent.context_engine import ContextEngine

class MyEngine(ContextEngine):

    @property
    def name(self) -> str: ...          # must equal the config.yaml value

    def update_from_response(self, usage: dict) -> None: ...
        # usage always has prompt_tokens / completion_tokens / total_tokens;
        # newer hosts also send input_tokens, output_tokens, cache_read_tokens,
        # cache_write_tokens, reasoning_tokens — treat those as OPTIONAL.

    def should_compress(self, prompt_tokens: int = None) -> bool: ...

    def compress(
        self,
        messages: List[Dict[str, Any]],
        current_tokens: Optional[int] = None,
        focus_topic: Optional[str] = None,
        force: bool = False,                 # bypass an engine-owned cooldown
        memory_context: str = "",            # text from memory providers pre-compaction
    ) -> List[Dict[str, Any]]: ...
        # Host filters unsupported optional args by signature, so older
        # engines that omit `force` / `memory_context` still load.
```

`messages` is a valid OpenAI-format sequence; whatever you return must also be one.

## Class attributes the host reads directly

```python
last_prompt_tokens: int = 0
last_completion_tokens: int = 0
last_total_tokens: int = 0
threshold_tokens: int = 0        # when compaction triggers
context_length: int = 0          # model's window
compression_count: int = 0       # how many times compress() ran
```

Engines MUST maintain these — `run_agent.py` reads them for the status display.

Tunable class defaults: `threshold_percent = 0.75`, `protect_first_n = 3`,
`protect_last_n = 6`, `emit_automatic_compaction_status = True`.

`protect_first_n` counts **non-system head messages** kept verbatim, *in addition to*
the system prompt (always implicitly protected). Default 3 preserves the historical
"system + first 3" head shape.

## Optional methods (all have safe defaults)

| Method | Default | Override when |
|---|---|---|
| `prune_tool_results_only(messages, current_tokens=None) -> (list, int)` | safe no-op, returns `(messages, 0)` | You can trim old tool-result payloads **without an LLM call**. Driven by a low, cost-oriented trigger independent of `should_compress()`. **The natural home for decision-guided pruning.** |
| `should_compress_info(prompt_tokens) -> (bool, reason)` | wraps `should_compress` | You have block reasons (cooldown, anti-thrash) worth surfacing to the user |
| `select_context(request_messages, *, conversation_messages, incoming_message, budget_tokens)` | `None` (no-op) | You *select/route* which context enters **this** request. Request-only; persisted history never mutated; runs before cache-control and all sanitizers |
| `on_turn_complete(messages, usage=None, **kwargs)` | no-op | Post-turn observation/ingestion. Best-effort: abnormal early returns (content-policy block, provider terminal failure) do **not** emit it |
| `should_compress_preflight(messages)` | `False` | You can cheaply estimate before the API call |
| `should_defer_preflight_to_real_usage(rough_tokens)` | `False` | Avoid re-compacting off a known-noisy rough estimate |
| `get_automatic_compaction_status_message(...)` | default message | Customize/silence routine automatic status |
| `has_content_to_compress(messages)` | `True` | Cheap introspection so gateway `/compress` can say "nothing to compress yet" without an LLM call |
| `on_session_start(session_id, **kwargs)` | no-op | Load persisted state (DAG, store) |
| `on_session_end(session_id, messages)` | no-op | Flush state, close connections. **Real boundaries only** — not per-turn |
| `on_session_reset()` | resets counters | Per-session state to clear (`/new`, `/reset`) |
| `get_tool_schemas()` / `handle_tool_call(name, args, **kwargs)` | `[]` / error JSON | You expose agent-callable tools. Injected at startup, dispatched automatically, gated by the `context_engine` toolset |
| `get_status()` | standard token/threshold dict | Custom metrics |
| `update_model(model, context_length, base_url, api_key, provider, api_mode)` | updates `context_length` + `threshold_tokens` | Own compaction policy; may honor or ignore `model_thresholds` |

## Lifecycle

```
1. Engine instantiated (plugin load or directory discovery)
2. on_session_start()      — conversation begins
3. update_from_response()  — after each API call
4. should_compress()       — checked each turn
5. compress()              — called when should_compress() returns True
6. on_session_end()        — real session boundary (CLI exit, /reset, gateway expiry)
```

## Config surface

```yaml
context:
  engine: "compressor"     # default built-in; set to your plugin's name to activate
```

A representative live `compression` block (defaults vary — always read the real one):

```
enabled: true            progress_notices: false    threshold: 0.5
threshold_tokens: null   target_ratio: 0.2          tail_mode: legacy
protect_last_n: 20       min_tail_user_messages: 1  max_attempts: 3
proactive_prune_tokens: 0                          # <-- off by default
proactive_prune_min_result_chars: 8000
proactive_prune_min_reclaim_tokens: 4096
micro_compact: false     micro_compact_every_n_turns: 1
hygiene_hard_message_limit: 400
hygiene_timeout_seconds: 30
context_timeout_seconds: 120                       # <-- pooled-thread timeout
```

Everything in `compression.*` is built-in-specific **except**
`compression.model_thresholds`, which is part of the engine contract.

Useful for reference implementations: `defer_context_engine_notification` and
`finalize_context_engine_compression_notification` are the host-side helpers used at
CLI / gateway / TUI call sites.

## Decision-guided pruning — verified model API

TypeSafe's **Jev** answers in exactly the per-item probability shape this needs.

```
POST https://api.typesafe.ai/v1/systemone
Authorization: Bearer $TYPESAFE_API_KEY
Content-Type: application/json

{ "model": "jev-latest", "state": {...}, "questions": {...} }
```

- `state` — arbitrary JSON facts. Prefer named fields. Reference nested values with
  backticked paths like `ticket.messages[0].text`.
- `questions` — named questions, each with `instructions` and `criteria`. Question
  **IDs are for code and are never sent to the model**, so each question must carry
  its complete meaning in `instructions`.
- Answer shapes on the response, per question name:
  - `{"noul": <float>}` — probability of yes (use one per label when several may apply)
  - `{"score": <float>}` — probability-weighted position on ordered levels
  - `{"choice": <string>}` — picks one option; the distribution compares options
- Also returns `usage` (`input_tokens`, `output_tokens`) and the resolved `model`.

### Measured on a live probe

A single request carrying 8 questions over a ~2k-token `state`:

```
model : jev-1.13.0        (jev-latest resolves to a concrete version)
usage : 1540 in / 156 out tokens
8/8 questions answered, decisions: 3 TRUNCATE, 1 DROP, 1 pinned KEEP
```

At the `$0.042 / million input tokens` rate used in the reference integration, a
compaction pass is on the order of **$0.001–$0.002** — noise next to the
main-model summary call it replaces.

### Prompting notes that mattered

- Ask both questions **per call** and treat them independently — the call and its
  result are separately useful.
- Pin the first message and the newest N. Never let the model vote on those; a
  user-set constraint stated in message 1 must survive unconditionally.
- State the *why* in `criteria`, not just the label. "True: exact contents are needed
  later (error text, line numbers); False: stale, superseded, or cheaply
  reproducible" produced sensible splits; bare `true`/`false` labels do not.
- Corroborating evidence the approach works: the same pattern is already deployed in
  the reference environment for a *different* domain (judging auction lots), using
  this identical endpoint, model and answer shape.

## Not verified

- No context-engine plugin has been loaded end-to-end in this environment.
  `plugin.yaml` fields were inferred from the loader's requirement (manifest +
  `__init__.py` with `register(ctx)`) and from other plugin types
  (`plugins/image_gen/*/plugin.yaml`, `plugins/platforms/*/plugin.yaml`).
- Whether `context.engine` accepts an arbitrary user-plugin name is documented
  ("checks the generic plugin system") but untested here. Building the smallest
  possible engine is the way to confirm both open questions.
