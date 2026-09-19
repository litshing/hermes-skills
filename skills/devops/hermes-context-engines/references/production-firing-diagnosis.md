# Why a plugin engine can register, pass its tests, and still do NOTHING

Written after a full session spent chasing exactly that. Read this before claiming a
context-engine plugin is "working" — registration and unit tests are **not** evidence.

## The headline

A plugin engine can be:

- `enabled` in `hermes plugins list`
- `registered context engine: <name>` in the log
- `context.engine` set to it in config
- passing all its contract tests

…and still make **zero** judgment calls in production, because every skip path in the
pre-pass is **silent**. There is no warning, no log line, no counter in the log. The
engine degrades to exactly the built-in behaviour and nothing tells you.

**Never report "the engine is live" from registration alone.** Prove a decision
happened (see *Diagnostic that actually works* below).

## What DID work (worth keeping)

- Engine built: `~/.hermes/plugins/jev-compaction/` — `plugin.yaml`, `__init__.py`,
  `jev.py`, `tests/`.
- Its suite **does** run and passes: **26 passed, 0 failed, 1 skipped** (the skip is
  the opt-in live-API test). pytest's collector cannot handle the hyphenated
  directory, so drive it with a standalone runner that adds the plugin dir to
  `sys.path` rather than fighting `--import-mode`.
- `hermes plugins enable <name>` → then **gateway restart** → registration confirmed:
  `Plugin 'jev-compaction' registered context engine: jev-compaction`.
- The two plugins are genuinely wired: photo gate + lot ranker in the antiques
  pipeline, and the memory gate loads (`MemoryGate`, `judge`, `JUDGED_ACTIONS`).

## Verified host-contract facts (each cost real time to find)

### 1. A plugin reads its own config namespace — not `compression.*`

The engine resolved its knobs from **`context.<plugin-key>`** in `config.yaml`
(here `context.jev`), merged over its internal defaults. So tuning
`compression.protect_last_n` does **nothing** for a plugin that keeps its own copy.

Worse, the protection value is combined with `max()`:

```python
protect_last = max(_cfg_int(cfg, "protect_last_n", 20), protect_tail_count)
#                                plugin default 20        ^ host's value
```

**A plugin default of 20 silently overrides a lowered host value.** Lowering
`compression.protect_last_n` to 3 had no effect whatsoever. Set BOTH, or set the
plugin's own key.

Setting an unregistered key works but warns — that warning is harmless, the plugin
reads the raw file:

```
⚠ 'context.jev.protect_last_n' is not a recognized config key — saved anyway
```

### 2. Candidate selection filters by ABSOLUTE message index

`iter_candidates()` computes `head_end` from `protect_first_n` and skips any call
whose assistant message index is below it:

```python
if a_i < head_end or r_i < head_end or a_i >= tail_start or r_i >= tail_start:
    continue
```

**Consequence:** when a model batches every tool call into ONE assistant message near
the top of the transcript — which agents do all the time — that whole batch sits
inside the protected head and yields **0 candidates**. The engine then skips, silently.

Test transcripts must have tool calls spread through the *middle*, or `protect_first_n`
must be lowered, or the result is meaningless.

### 3. Minimum session size for any pruning to be possible

```python
if len(messages) <= protect_last_n + protect_first_n + 1:
    return messages, 0        # early return, no-op, no log
```

With the stock `protect_last_n=20` / `protect_first_n=3`, a session needs **>24
messages** before anything is even considered. Short isolated test sessions can
therefore never prune. This is by design, not a bug — but it makes short-session
tests worthless.

### 4. An empty candidate list makes the judgment API return HTTP 422

`_ask_jev` does not guard against an empty batch: it builds empty questions and
posts them, and TypeSafe answers `HTTP Error 422: Unprocessable Entity`. **The
exception is not caught and not logged.** Guard the call with
`if not fresh: return None, 0` and catch transport errors explicitly.

### 5. The `tools.override` capability deny is NORMAL — ignore it

```
capability_check plugin=<p> capability=tools.override decision=deny evidence=not granted
```

Appears for every plugin that does not declare `capabilities:` in `plugin.yaml`. An
engine prunes through the engine's own return contract; it does not need to override
tools. This is default-deny probing, not a failure. Do not chase it.

### 6. Enabling a plugin requires a gateway restart — know the log signature

A running gateway does not learn about a newly enabled plugin. The tell, repeated
once per turn until you restart:

```
WARNING run_agent: Context engine '<name>' not found — falling back to built-in compressor
```

After a restart the same log gains the registration line and the warnings stop. Last
warning timestamp vs. gateway start time is a clean way to prove which side of the
restart you are on.

### 7. `hermes chat -q` is the isolated-session tool

```bash
hermes chat -q "Read these N files with read_file, then summarise each: <paths>" \
  --yolo --max-turns 12
```

Creates a fresh session id, runs one turn, exits. `--yolo` prevents an approval hang.
Good for exercising a compaction path without touching the live conversation.

## Diagnostic that actually works

Grepping logs tells you nothing (see the silent skips). **Invoke the engine
in-process and read its own counters.** This is what broke the case open.

Call the engine the way the HOST loads it — as `hermes_plugins.<plugin_underscored>`:

```python
import os, sys, tempfile, importlib
home = os.path.expanduser("~")
plug = os.path.join(home, ".hermes", "plugins", "jev-compaction")
tmp = tempfile.mkdtemp()
pkg = os.path.join(tmp, "hermes_plugins")
os.makedirs(pkg, exist_ok=True)
open(os.path.join(pkg, "__init__.py"), "w").close()
os.symlink(plug, os.path.join(pkg, "jev_compaction"))   # dir name -> submodule name
sys.path.insert(0, tmp)
sys.path.insert(0, os.path.join(home, ".hermes", "hermes-agent"))
mod = importlib.import_module("hermes_plugins.jev_compaction")
```

Then build a synthetic transcript and walk inward one gate at a time:

```python
eng  = mod.JevContextCompressor(model="")
cfg  = eng._jev_cfg                       # 1. what config did it ACTUALLY resolve?
cand = jev.iter_candidates(msgs, protect_first_n=..., protect_last_n=...,
                           min_result_chars=...)
print(len(cand))                          # 2. how many candidates survive?
print(eng._ask_jev(msgs, cand, cfg))      # 3. does the API call return or raise?
out, n = eng._prune_old_tool_results(msgs, protect_tail_count=3,
                                     protect_tail_tokens=None, min_prune_chars=8000)
print(n, out is not msgs)                 # 4. did anything change?
print(eng.get_status())                   # 5. the counters — the real verdict
```

The counters are the answer:
`{'passes': 0, 'requests': 0, 'judged': 0, 'dropped': 0, 'truncated': 0, 'kept': 0,
'errors': 0, 'skipped': 1}` means **skipped, no API call** — regardless of how many
messages changed, because the *built-in* passes still do the editing. A non-zero `n`
from step 4 is **not** evidence the plugin ran.

Note the trap: `_prune_old_tool_results` changed 8 messages while the plugin made zero
requests. Only the counters distinguish plugin work from built-in work.

## STILL UNRESOLVED — the host call site

The prune is invoked from `agent/conversation_loop.py` (~line 7377):

```python
_prune = getattr(_compressor, "prune_tool_results_only", None)
if callable(_prune):
    _pruned_msgs, _pruned_n = _prune(messages, current_tokens=_real_tokens)
```

With `compression.proactive_prune_tokens = 8000` and `_real_tokens ≈ 78_000` (clearly
above the trigger), and candidate counts provably non-zero, **it still never fired** —
no `prune_tool_results_only` activity at all. The gate is therefore in an **enclosing
condition** of that block, not in the engine.

**Do not guess at this.** The next step is to read the enclosing `if` chain (the
call site is nested fairly deep; walk backwards by indentation to collect the
enclosing conditions, then inspect the guards mentioning `_real_tokens`,
`should_compress`, `_block_reason`, or a turn budget). Until that is read and
satisfied, the honest status is: **engine correct in isolation, never yet exercised
in production.**

## Honesty rule for this whole area

Do not describe the engine as working, live, or saving tokens until a decision has been
observed in a real session (a counter moved, or a decision log line from the plugin).
Earlier measurements taken by calling `_jev_prepass()` **directly** — e.g. "4.1×
token reduction", "8 dropped, 2 truncated" — are valid evidence about the *engine
logic* and **zero** evidence about production behaviour, because they bypass the host
call site that this session proved is not firing.

## Test-harness hygiene

Debugging this required temporarily lowering protection knobs. Restore them, or the
next real compaction behaves unexpectedly:

```bash
hermes config unset compression.proactive_prune_tokens
hermes config set   compression.protect_last_n 20
hermes config unset context.jev.protect_last_n
hermes config unset context.jev.min_candidates
hermes config unset context.jev.protect_first_n
hermes config set   context.engine <engine-name>
```

Also: the terminal guard **blocks any script containing a gateway-restart literal**,
even one that only prints it as instructions for the user. Issue the config changes
and the test session as separate plain commands instead of bundling them into a
script that also mentions restarting the gateway.
