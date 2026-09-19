---
name: hermes-context-engines
description: Use when tuning or replacing Hermes context engines.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags:
      - hermes
      - context
      - compaction
      - compression
      - plugins
      - architecture
    related_skills:
      - hermes-cron-ops
      - writing-skills
---

# Hermes Context Engines

## When to Use

- The user asks how Hermes decides to compact, why a session compacted, or why
  archived content went missing.
- You need to **reduce context growth**: re-sent tool output, repeated file dumps,
  long transcripts.
- The user wants an alternative compaction strategy (lossless, decision-guided,
  retrieval-based) instead of the built-in summary.
- You are about to claim "Hermes can't hook into compaction" — check this first.

## Overview

Hermes's context management is built on a **pluggable ABC**, not a fixed pipeline.
The built-in `ContextCompressor` is only the *default implementation*; a plugin can
replace it wholesale. This is a documented, sanctioned extension point — not a hack.

**Never tell the user compaction is not extensible without reading
`agent/context_engine.py` first.** The interface is ~490 lines and includes hooks
that make a cheap, LLM-free compaction pass possible.

## Layer 0 — the built-in knobs (free, no code)

Before writing any engine, check whether config alone solves the problem. Inspect
the live values rather than guessing:

```bash
hermes config get compression
hermes config get context.engine
```

The ones that matter for runaway context:

| Key | Meaning |
|---|---|
| `compression.proactive_prune_tokens` | Deterministic, **LLM-free** trimming of old tool-result payloads. `0` = **disabled**. |
| `compression.proactive_prune_min_result_chars` | Only results larger than this are candidates |
| `compression.proactive_prune_min_reclaim_tokens` | Minimum reclaimed tokens before a prune fires |
| `compression.threshold` | Fraction of the window that triggers compaction |
| `compression.protect_last_n` | Newest messages never touched |
| `compression.micro_compact` | Per-turn micro compaction |
| `compression.context_timeout_seconds` | Host timeout for the compression pass (runs on a pooled thread) |

The built-in `prune_tool_results_only()` is exposed on the ABC and driven by
`proactive_prune_tokens`; on a typical install it is **off by default**. Enabling it
is a zero-cost win — but it prunes by **size**, not by **whether the content still
matters**. That gap is the entire argument for a decision-guided engine.

## Layer 1 — replace the engine with a plugin

### Where it lives and how it is selected

```
~/.hermes/plugins/<plugin-name>/
├── plugin.yaml      # manifest (name, description, version, userConfig…)
└── __init__.py      # def register(ctx): ctx.register_context_engine(JevEngine(...))
```

```bash
hermes config set context.engine <engine-name>    # must equal the engine's `name` property
```

Resolution order for `context.engine`:
1. `plugins/context_engine/<name>/` directory discovery
2. the generic plugin system (`register_context_engine()`)

Plugin engines are **never auto-activated** — the default `"compressor"` always
uses the built-in. Selection is explicit and therefore safe to ship.

### Plugin sources (from the loader's own docstring)

1. **Bundled** — `<repo>/plugins/<name>/` (the `memory/` and `context_engine/`
   subdirs are excluded here; they have their own discovery paths)
2. **User** — `~/.hermes/plugins/<name>/`  ← where a user plugin belongs
3. **Project** — `./.hermes/plugins/<name>/` (opt-in via `HERMES_ENABLE_PROJECT_PLUGINS`)
4. **Pip** — packages exposing the `hermes_agent.plugins` entry-point group

Later sources override earlier ones on name collision. **Each directory plugin needs
both a `plugin.yaml` manifest and an `__init__.py` with a `register(ctx)` function.**

### Only one engine can be active

A second plugin attempting `register_context_engine()` is rejected with a warning.
This drives the single most important design decision (see below): a custom engine
**replaces** the built-in, so it must not throw the built-in away.

## Design rule: WRAP the built-in, don't reimplement it

Because the engine is a total replacement, the safe architecture is a **delegating
wrapper**:

- Hold an inner `ContextCompressor` instance.
- Forward `compress()`, `update_from_response()`, `should_compress()`,
  `update_model()`, lifecycle hooks to it unchanged.
- Override **only** the hook you actually improve — normally
  `prune_tool_results_only()`, which is specified as *"deterministically trim old
  tool-result payloads **without an LLM call**"* on a low, cost-oriented trigger,
  independent of `should_compress()`.

Worst case then behaves exactly like the built-in. A custom engine that reimplements
summarization is strictly riskier for no gain.

## Contracts you must respect

- **Fail-open.** A missing hook, an exception, or an invalid return leaves the
  request untouched — a failing engine is never worse than no engine. That also
  means **failures are silent**: add your own logging or the user will never know.
- **Thread safety.** With `compression.context_timeout_seconds > 0` (default 120),
  the entire compression pass runs on a **pooled daemon thread** with a host-side
  timeout. Calls may arrive on an arbitrary thread; do not rely on thread-affinity
  or `threading.local` shared with the conversation thread. On timeout your
  still-running work is **discarded** — never publish to durable/external state
  outside the commit. Passes for *different* sessions can run concurrently, so a
  single shared engine instance MUST be thread-safe.
- **Prompt caching is sacred.** Only `select_context()` may replace the per-request
  message list; `compress()` shrinking persisted history is the one sanctioned
  exception to cache-prefix stability. Return stable selections when nothing changed,
  or you forfeit cache reuse every turn.
- **`compression.*` is built-in-specific**, with one exception:
  `compression.model_thresholds` is part of the engine contract. The host assigns it
  to `engine.model_thresholds` *before* the initial `update_model()`. Reuse
  `from agent.context_compressor import resolve_model_threshold` for the same logic.
- **Engine tools** returned from `get_tool_schemas()` are injected into the agent's
  tool list at startup and dispatched automatically — no registry registration — and
  are gated by the `context_engine` toolset.

## Alternative strategy: decision-guided compaction

The gap Layer 0 leaves is *judgment*: size-based pruning cannot tell a stale
1,200-char grep from the 4,000-char stack trace that explains the bug. A
decision-scoring model can.

The shape that fits the ABC: ask a fast judgment model two questions per
non-pinned tool call — **should the call stay** (does knowing it happened still
matter?), and **should the result stay verbatim** (are the contents still needed, or
would re-running the tool do?). Then apply thresholds:

- result prob ≥ threshold → keep call + result
- else call prob ≥ threshold → keep the call, truncate the result to a head + note
- else → drop the call and result together

Everything that is *not* a tool call/result — user text, assistant text,
constraints, conclusions — stays **verbatim**. That is the whole point versus a
summary: a summary is lossy, and skill content / file paths / constraints vanish
from it.

TypeSafe's **Jev** is one model that answers in exactly this shape (verified live:
`noul` probabilities, `score`, `choice`, all with `instructions` + `criteria`).
See `references/context-engine-api.md` for the API surface and measured cost.

> ⚠️ **Status: designed, NOT built.** This section is a validated *architecture*
> (the ABC, hooks, thresholds and API were all verified), but no Jev compaction
> engine has been implemented or run in this environment yet. Do not describe it to
> the user as working.

## Verification

The repo ships an ABC contract suite — use it as the acceptance test instead of
inventing your own:

```bash
cd ~/.hermes/hermes-agent
pytest tests/agent/test_context_engine.py -v      # full ABC contract
pytest tests/gateway/test_compress_plugin_engine.py -v
```

The second one is a regression test written for a real bug: the gateway `/compress`
handler once reached into `ContextCompressor`-only private helpers
(`_align_boundary_forward`, `_find_tail_cut_by_tokens`), which broke every plugin
engine with `AttributeError`. Those helpers are **not** part of the ABC — a plugin
engine must satisfy only the documented interface, and the gateway must not reach
past it.

Minimum sanity check for any engine:

```python
from agent.context_engine import ContextEngine
engine = YourEngine(context_length=200000)
assert isinstance(engine, ContextEngine)
assert engine.name == "your-name"
```

## Pitfalls

- **Concluding "compaction isn't hookable".** It is. Read `agent/context_engine.py`.
- **Reimplementing summarization.** Wrap the built-in and override one hook.
- **Publishing a plugin that edits core files.** Plugins live in their own
  directory and work within the provided ABC; a plugin needing core edits is a
  design error, not a reason to fork.
- **Forgetting `plugin.yaml`.** A directory with only `__init__.py` will not load.
- **Assuming engines auto-activate.** They never do; `context.engine` must be set.
- **Doing durable I/O inside `compress()`.** On host timeout the pass is discarded.
- **Trusting a rough pre-compaction token estimate.** See
  `should_defer_preflight_to_real_usage()`, which exists precisely so a
  known-noisy estimate does not trigger a redundant re-compaction after a
  compressed request already fit.

## Support files

- `references/context-engine-api.md` — exact ABC surface, file/doc paths, config
  keys, resolution order, and the verified judgment-model API + measured cost.
