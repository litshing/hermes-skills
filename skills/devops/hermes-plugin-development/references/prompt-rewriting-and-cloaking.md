# Rewriting the OUTBOUND prompt from a plugin (cloaking / redaction)

Verified 2026-09-18 while building `~/.hermes/plugins/cloak-guard/` — a plugin
that replaces personal data in the prompt before it reaches the provider and
puts the real values back into the reply. Everything below was read out of the
running tree; line numbers are from `~/.hermes/hermes-agent` at that date.

## The two seams

| Seam | Where (verified) | Contract |
|---|---|---|
| `llm_request` middleware | `agent/conversation_loop.py` ~2819 → `hermes_cli.middleware.apply_llm_request_middleware` | payload `request` = the provider kwargs (`messages` or, for Responses-style backends, `input`); return `{"request": {...}}` and that dict **becomes** the call (`api_kwargs = _llm_request_mw.payload`). A non-dict return, or a dict without `"request"`, is **ignored** (fail-open). Optional `source` / `reason` land in the trace. Context kwargs: `session_id`, `model`, `provider`, `base_url`, `api_mode`, `api_call_count`, `task_id`, `turn_id`, `api_request_id`. |
| `transform_llm_output` hook | `agent/turn_finalizer.py` ~592 | Fires **once per turn** on the final response text. **First hook to return a non-empty string wins**; `None`/`""` leaves the text unchanged. Signature: `response_text`, `session_id`, `model`, `platform`. |

Related but *not* the prompt path: `transform_tool_result`, `pre_api_request`,
and `ctx.register_redaction_patterns(...)` → `agent/redact.py`
(`redact_sensitive_text`). Read its 25 call sites: every one is logs, stdout,
`send_message`, kanban summaries — i.e. **emitted text**, never the request the
model receives. Extending it is fine for secret scrubbing and useless for
prompt cloaking. Say so instead of reaching for it.

## ⚠️ The constraint that shapes everything: prompt-cache determinism

The provider's prompt cache is keyed on the **exact bytes** of the request
prefix. This user's measured mix — 586M cache-read tokens/month on a 98.1%
cache-hit rate — prices as:

```
cache HIT  586M × $0.003/M  ≈   $2 /month
cache MISS 586M × $0.15–0.30/M  ≈  $88–176 /month      ← same tokens, 50–100x
```

So a redactor that produces a *different* placeholder each turn (random token,
timestamped token, per-call counter without a value key) silently converts every
cached read into a miss. Three rules follow, and all three are testable:

1. **Deterministic mapping**: `(kind, value) → token` in a vault; the same value
   always yields the same placeholder, process-wide.
2. **Idempotent pass**: the placeholder shape (`[[EMAIL_1]]`) must not match any
   detector, so re-cloaking an already-cloaked transcript is a byte-identical
   no-op.
3. **Return `None` when nothing matched** — never rebuild and re-emit an
   unchanged request. If the payload is byte-identical anyway this is harmless,
   but it removes the entire class of accidental churn, and it keeps the
   middleware a genuine no-op on clean turns.

Tests that pin it (these are the ones worth copying to any prompt-rewriting
plugin):

```python
def test_placeholder_is_deterministic(...):   # same value -> identical bytes, two passes
def test_second_pass_changes_nothing(...):    # re-running over cloaked text returns None
def test_clean_request_is_never_touched(...): # no match -> None, original object untouched
```

## Traps

- **Never cloak assistant `tool_calls[].function.arguments`.** They are the
  model's *instructions to a tool*, not data. Cloaking them (as a naive "walk
  every string leaf" pass does) hands the tool `[[EMAIL_1]]` and breaks
  execution. Cloak: user text, assistant text, **tool results** (the biggest
  leak vector — file reads, search output), and list-shaped content parts.
- `messages` is not always the key: Responses-style backends use `input`. Pick
  whichever is a list.
- A remote cloak/redaction API in this seam is the wrong shape: this user runs
  ~3,700 API calls/week, so a per-call network hop on the hot path doubles
  latency. Keep the prompt path local and synchronous; reserve the remote
  service for tool/data flows.
- v1 limits worth stating to the user rather than discovering later: names,
  street addresses, and employer names need an explicit `literal_terms` list;
  images/audio are untouched; only the turn's *final* text is uncloaked
  (interim/streamed messages would need `on_interim_message`).

## Ship `audit` first, and COUNT the detectors against the real corpus

The default mode must be `audit`: count and log what *would* be cloaked, change
nothing. Then run the detector set over the actual local corpus before anyone
flips to `enforce` — this is what catches a bad regex, and the numbers are
brutal:

| Detector | Naive hits | Cause | Fix | After |
|---|---|---|---|---|
| Canadian postal (`[A-Za-z]\d[A-Za-z][ -]?\d[A-Za-z]\d`) | **332** | 6-char CSS hex colours (`d4d4d4`, `F5F5F5`) in design templates | require the space/dash separator | **8** |
| Long digit runs (12–19 digits) | 20 | 13-digit epoch-millisecond timestamps | Luhn-validate the match before counting it | **2** |

Corpus: 795 files / 6.1M chars of memory files, recent `state.db` messages, and
skills. Total hits 419 → 80. Report counts **by kind only** — never echo matched
values into a log or a chat.

Cheap validator hook, so additional kinds stay declarative:

```python
VALIDATORS = {"ACCT": _luhn_ok}          # kind -> predicate a match must satisfy
# in the scan: if validator and not validator(match.group(0)): continue
```

## Test harness for a hyphenated plugin dir

Two working routes (the plugin dir `cloak-guard` is not importable by name):

```bash
# 1. pytest from a NEUTRAL cwd with the absolute test path
cd /tmp && ~/.hermes/hermes-agent/venv/bin/python3 -m pytest \
    ~/.hermes/plugins/cloak-guard/tests/test_cloak_guard.py -q
```

```python
# 2. load the plugin as a submodule of a synthetic parent package, so the
#    plugin's own `from . import patterns` resolves
pkg = types.ModuleType("cloak_pkg"); pkg.__path__ = [PLUGIN_DIR]
sys.modules["cloak_pkg"] = pkg
spec = importlib.util.spec_from_file_location("cloak_under_test",
        os.path.join(PLUGIN_DIR, "__init__.py"), submodule_search_locations=[PLUGIN_DIR])
mod = importlib.util.module_from_spec(spec); sys.modules["cloak_under_test"] = mod
spec.loader.exec_module(mod)
```

And exercise the **real host chain** rather than a local copy — monkeypatch the
two functions `hermes_cli.middleware` delegates to:

```python
import hermes_cli.plugins as plugins_mod
monkeypatch.setattr(plugins_mod, "has_middleware", lambda kind: kind == "llm_request")
monkeypatch.setattr(plugins_mod, "invoke_middleware",
                    lambda kind, **kw: [mod.on_llm_request(**kw)] if kind == "llm_request" else [])
res = apply_llm_request_middleware({"messages": [{"role": "user", "content": text}]},
                                  session_id="s1")
assert res.changed and res.trace[0]["source"] == "cloak-guard"
```

## Shipped shape (reuse as the template)

```
~/.hermes/plugins/cloak-guard/
  plugin.yaml                 # name/version/kind: standalone + a description ending in the failure mode
  __init__.py                 # DEFAULTS dict, _cfg() from config.yaml, register(ctx), fail-open wrappers
  vault.py                    # deterministic value<->[[KIND_n]] map, thread-safe, bounded, never persisted
  patterns.py                 # ordered detectors + VALIDATORS + spans() (earliest start wins, longer wins ties)
  tests/test_cloak_guard.py   # 14 tests, all green
```

Config lives under `cloak_guard:` in `config.yaml` (`mode`, `max_entries`,
`kinds`, `custom_patterns`, `literal_terms`, `cloak_tool_results`,
`cloak_assistant_text`) — behavioural settings stay in `config.yaml`, never
`.env`. Activation is still two steps: `hermes plugins enable cloak-guard` +
`hermes gateway restart`.
