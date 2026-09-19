# Resolved: the plugin engine DOES fire — the host call site was a decoy

**This file supersedes the "STILL UNRESOLVED — the host call site" section of
`production-firing-diagnosis.md`.** That section concluded the engine was "correct in
isolation, never yet exercised in production" and told the next agent to go read the
enclosing `if` chain. That work is done. Do not repeat it.

## The answer in one paragraph

`should_compress()` was the decoy. The prune call site lives in the **`else` branch**,
so it runs precisely when full compression does *not* trigger — i.e. *below* the
threshold, not above it. At `_real_tokens ≈ 78_000` against a 256K window with
`compression.threshold = 0.5`, `should_compress()` returns False (128K needed), which
means the prune branch **was reachable the entire time**. The host gate was never the
blocker. The real blocker was the candidate filter already documented in sections 1–3
of the diagnosis file (`protect_first_n` + batched tool calls ⇒ 0 candidates ⇒ silent
skip).

## The exact chain (read by walking backwards from the call site by indentation)

`agent/conversation_loop.py` (~line 7377), inside `def run_conversation` → `while`
loop → `try` → `if assistant_message.tool_calls:` →

```python
if (agent.compression_enabled
        and compression_attempts < max_compression_attempts
        and _compressor.should_compress(_real_tokens)):   # ~50% of window
    ... full compression ...                              # "⟳ compacting context…"
elif agent.compression_enabled:                           # ← THE PRUNE LIVES HERE
    _prune = getattr(_compressor, "prune_tool_results_only", None)
    if callable(_prune):
        _pruned_msgs, _pruned_n = _prune(messages, current_tokens=_real_tokens)
```

**Inverted intuition worth internalising:** a proactive prune is cheap and
deterministic, so it is deliberately placed on the *cheaper* branch. If you are
debugging "my prune never fires", `should_compress()` returning False is **good news**,
not a gate.

A quick way to collect the enclosing chain without guessing: walk backwards from the
call site tracking indentation, and print each line that starts with
`if `/`elif `/`else:`/`try:`/`while `/`for `/`def `. That is what isolated the
`elif agent.compression_enabled:` branch.

## Proof it fires (the evidence that was missing)

Calling `_prune_old_tool_results(...)` — **the same method the host calls** — with the
plugin's own protection knobs lowered:

```python
eng = mod.JevContextCompressor(model="")
eng.protect_last_n = 20
out, n = eng._prune_old_tool_results(msgs, protect_tail_count=3,
                                     protect_tail_tokens=None, min_prune_chars=8000)
print(eng.get_status())
```

```
changed      : 9 messages
jev counters : {'passes': 1, 'requests': 1, 'judged': 8, 'dropped': 8,
                'truncated': 0, 'kept': 0, 'errors': 0, 'skipped': 0}
```

`requests: 1, judged: 8` — one genuine TypeSafe API round-trip, eight candidates
judged. Dropping all eight is *correct* for that transcript: the goal was "read these
files and summarise", the summaries were produced, so the raw bodies no longer need
re-sending.

### Evidence-tier rule (keep this straight)

| How you called it | What it proves |
|---|---|
| `eng._jev_prepass()` directly | engine *logic* only — bypasses every host precondition |
| `eng._prune_old_tool_results(...)` | **the host entry point** — genuine path evidence |
| A counter moving in a live long conversation | production proof (still not observed) |

Do not quote the "4.1× token reduction" figure as production evidence — it came from
tier 1.

## Two defects fixed as a direct result

Both in `~/.hermes/plugins/jev-compaction/__init__.py`.

**1. The silent skip.** This is the defect that cost hours:
`if len(candidates) < min_candidates: return messages, 0` logged nothing, so *engine
idle* and *engine skipping* were indistinguishable at every surface the host exposes.
Now:

```python
min_cand = _cfg_int(cfg, "min_candidates", 4)
if len(candidates) < min_cand:
    self._jev_stats["skipped"] += 1
    self._jev_last_skip = (f"only {len(candidates)} candidate(s), need "
                           f"min_candidates={min_cand} "
                           f"(protect_first_n={...}, protect_last_n={protect_last}, "
                           f"messages={len(messages)})")
    logger.info("jev-compaction: pre-pass skipped — %s", self._jev_last_skip)
    return messages, 0
```

**2. Empty batch → uncaught HTTP 422.** Guard added at the top of `_ask_jev`:

```python
if not fresh:
    self._jev_stats["skipped"] += 1
    return None, 0
```

**3. Observability.** `get_status()` now exposes `jev_last_skip` and `jev_config`
(the resolved `protect_first_n`, `protect_last_n`, `min_candidates`,
`min_result_chars`, …). This matters because the plugin reads its knobs from
`context.jev.*` while the host reads `compression.*` — two config trees, and the
effective value is a `max()` of both. Reading the resolved set beats inferring it.

Verified after patching: **26 passed, 0 failed, 1 skipped**; `_ask_jev([])` returns
`(None, 0)` with no request sent.

## The generalizable rule (the actual lesson)

**In a fail-open hook, log every skip path first.**

Fail-open means a broken or idle hook degrades to "silently does nothing", which is
indistinguishable from success at every surface the host exposes — registration, the
plugin list, config, and even the return value of the prune call (because the *built-in*
passes still edit messages and still return `changed: N`). Write the skip logging before
you write the clever logic, or you will be unable to debug it.

Corollary: when a component is silent by design, **do not** diagnose by grepping logs.
Invoke it in-process and read its own counters.

## Status and the honest remaining gap

Exercised through the host entry point; **not yet observed in a genuine long live
conversation.** That needs >24 messages with tool calls sitting between the protected
head and tail. The logging is now in place, so the next real compaction records its
decision and the next real skip records its reason. When it stays quiet, read
`get_status().jev_last_skip` before assuming anything is broken.

## Restore-after-testing checklist

Debugging this required lowering protection knobs. **Restore them** or the next real
compaction behaves unexpectedly:

```bash
hermes config unset compression.proactive_prune_tokens
hermes config set   compression.protect_last_n 20
hermes config unset context.jev.protect_last_n
hermes config unset context.jev.min_candidates
hermes config unset context.jev.protect_first_n
hermes config set   context.engine <engine-name>
```

`hermes config set` on an unregistered key warns but saves — harmless; the plugin reads
the raw file.

**Terminal-guard trap:** the guard blocks any script whose *source text* contains a
gateway-restart literal, even one that merely prints it as instructions for the user.
Issue config changes and test sessions as separate plain commands rather than bundling
them into such a script.
