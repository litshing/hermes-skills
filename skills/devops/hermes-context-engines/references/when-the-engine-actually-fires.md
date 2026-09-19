# When the engine actually fires (verified 2026-09-18)

> ⚠️ **CORRECTS THE SKILL BODY.** The main `SKILL.md` still carries a block reading
> *"Status: designed, NOT built… Do not describe it to the user as working."*
> **That is out of date.** Fix it next time SKILL.md is legitimately re-loadable
> (a fresh `skill_view` returning content — dedup re-views do NOT count, see the
> `read_before_write_required` guard).

## Status: BUILT and LIVE

`jev-compaction` is implemented at `~/.hermes/plugins/jev-compaction/`, registered,
and active as `context.engine`. Verified **through the host entry point**
(`_prune_old_tool_results` — not a direct library call, which is a weaker claim):

```
changed          : 9 messages
jev              : {'passes': 1, 'requests': 1, 'judged': 8,
                    'dropped': 8, 'truncated': 0, 'kept': 0,
                    'errors': 0, 'skipped': 0}
```

One real TypeSafe request, 8 candidates judged, 8 dropped, 0 errors. Its own suite
passes 26/26. Registered at gateway boot:

```
Plugin 'jev-compaction' registered context engine: jev-compaction
```

Engine registration is a **boot-time** event. Enabling the plugin on a *running*
gateway does nothing until the gateway restarts — before that the log shows
`Context engine 'jev-compaction' not found — falling back to built-in compressor`.
So: **"registered" ≠ "firing"; always check both the boot line and the counters.**

## The two protected windows, and the trap

A tool-call/result pair is only a candidate if it sits **outside both** windows:

```python
head_end   = protect_first_n                      # by ABSOLUTE message index
tail_start = max(context.jev.protect_last_n,      # engine's own tree
                 compression.protect_last_n)      # the built-in's tree
```

Three separate ways this silently yields **zero candidates**:

1. **Wrong config tree.** The engine resolves its knobs from **`context.jev.*`**,
   *not* `compression.*`. And because it takes the **`max()`** of the two
   `protect_last_n` values, its own default (20) wins — so lowering
   `compression.protect_last_n` on its own does **nothing at all**.

2. **Session too short.** With defaults (`protect_first_n: 3`, `protect_last_n: 20`)
   a session needs **more than ~23 messages** before any tool call is eligible.
   This is by design, not a bug.

3. **The real coverage gap — batched tool calls.** `protect_first_n` protects by
   *absolute message index*. If a model batches every tool call into **one** early
   assistant message, that single message lands inside the protected head and
   **all** of its calls are excluded → 0 candidates → silent no-op.
   A long production session spreads calls across many assistant messages, so it
   is fine; an isolated test session usually is not. Expect this whenever you
   ask a model to "read these 10 files" in one shot.

## Recipe: force a real prune for testing

Isolated session, cheap trigger (the LLM-free prune path), no summary call.
Use `hermes chat -q` — it is a fresh session and does not touch the live one.

```bash
hermes config set compression.proactive_prune_tokens 8000
hermes config set context.jev.protect_first_n 0     # ★ the decisive one
hermes config set context.jev.protect_last_n 2
hermes config set context.jev.min_candidates 2

hermes chat -q "Read these 10 files with read_file, then summarise each: ..." \
  --yolo --max-turns 12

# then RESTORE every one of them:
hermes config unset compression.proactive_prune_tokens
hermes config unset context.jev.protect_first_n
hermes config unset context.jev.protect_last_n
hermes config unset context.jev.min_candidates
hermes config set compression.protect_last_n 20
```

`protect_first_n 0` is the key knob. Without it a batched test transcript yields
zero candidates regardless of everything else. Setting these is safe while a
gateway runs: compaction only evaluates at **turn boundaries**, never mid-tool-call,
so a set → test → restore sequence inside one tool call cannot compact the live
session. Still restore them — they are not the values you want in production.

Note `compression.threshold_tokens: null` is the ratio path; setting it to an
absolute number is an alternative lever for the *full* compaction path, but that
path costs an LLM summarisation call, so prefer the prune recipe above.

## Reading the counters — is it broken, or just idle?

Ask the engine, not the logs:

```python
eng.get_status()   # -> {"jev": {...counters...}, "jev_last_skip": "...", "jev_config": {...}}
```

| Counters | Meaning |
|---|---|
| `passes:0, requests:0, skipped:1` | **Asked and declined** — nothing wrong. Read `jev_last_skip` for why. |
| `requests:1, judged:N, dropped:M` | It ran. `dropped:M` is real reclaimed context. |
| `errors:>0` + a `pre-pass failed` warning | It raised and failed open to the built-in. |

`passes:0, requests:0, skipped:0, errors:0` with changes still reported means the
changes came from the **built-in** passes, not from Jev. That distinction is easy
to miss and leads straight to a false "it works" conclusion.

## Defects found and fixed in this engine

Both were real, and both made the engine *look* broken when it was not:

- **Silent skip.** Exceeding `min_candidates` bailed out with no log line at all,
  making a deliberate no-op indistinguishable from a healthy engine with no work.
  Now logs `jev-compaction: pre-pass skipped — only N candidate(s), need
  min_candidates=M (protect_first_n=…, protect_last_n=…, messages=…)` and records
  `_jev_last_skip`, surfaced via `get_status()`.
- **Empty candidate list reached the API.** `_ask_jev([])` posted to TypeSafe and
  came back as a bare `HTTP Error 422`, which the caller read as "no answers"
  rather than "we asked nothing". Now returns `(None, 0)` before spending a request.

## Pitfalls

- **Concluding the engine is broken from a short test session.** Check message
  count against `protect_first_n + protect_last_n + 1` first.
- **Tuning `compression.*` when the engine reads `context.jev.*`.** The `max()`
  silently defeats you.
- **Treating `hermes config set` warnings as failure.** Custom keys like
  `context.jev.*` trigger *"'…' is not a recognized config key — it was saved
  anyway"*. That is the schema validator, not the engine; the plugin reads the
  file directly.
- **Trusting the absence of a log line.** Fail-open means silence. `get_status()`
  counters are the only reliable signal.
- **Editing SKILL.md after any other tool call in the turn.** The read-before-write
  guard requires a content-returning `skill_view` in the *same* turn, and a dedup
  re-view returns `content_returned: false`, which does not satisfy it. Patch
  SKILL.md first; use a new `references/` file (ungated) otherwise.
