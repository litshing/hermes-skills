# SKILL.md body corrections needed (stale claims in the main file)

**Read this before quoting the SKILL.md body.** Two parts of it are now out of
date and will lead you to tell the user something false. This file exists because
the background curator cannot reliably patch `SKILL.md` after any intervening
tool call in the same turn (see "Why this is a separate file" at the bottom).

## 1. The "⚠️ Status: designed, NOT built" block is WRONG — the engine exists

The body currently says, under *Alternative strategy: decision-guided compaction*:

> ⚠️ **Status: designed, NOT built.** … no Jev compaction engine has been
> implemented or run in this environment yet. Do not describe it to the user as
> working.

**Replace it with:**

> **Status: built, tested, registered, and proven to fire through the host entry
> point** (`jev-compaction` in `~/.hermes/plugins/`). 26/26 unit tests pass, and a
> real judgment-model round-trip was observed — `requests: 1, judged: 8,
> dropped: 8` — when `_prune_old_tool_results()` was called the way the host calls
> it.
>
> **The remaining honest gap:** it has not yet been observed firing inside a
> genuine long *live* conversation, because that needs >24 messages with tool
> calls sitting between the protected head and tail. Say "fires when the session
> is long enough", never a bare "it works".
>
> Full evidence chain, the two defects found, and the restore-after-testing
> checklist: `references/production-firing-resolved.md`.

Describing a built, tested, production-registered engine as unbuilt is worse than
saying nothing: it makes the next session tell the user to go build what they
already have.

## 2. The Pitfalls section is missing the gate that actually decides everything

The single most important operational fact about a candidate-selecting engine is
absent from the body. Add it to *Pitfalls*:

> - **Candidates live only between the protected head and the protected tail, so a
>   short or badly-shaped session yields ZERO candidates and the engine silently
>   behaves exactly like the built-in.** Two windows gate it and the effective
>   value is a `max()` of two different config trees:
>
>   `protect_last = max(context.jev.protect_last_n, compression.protect_last_n)`
>
>   With the defaults (`head 3`, `last 20`) a session needs **>24 messages** before
>   anything is eligible. Worse, models routinely batch *every* tool call of a turn
>   into **one** assistant message — if that message lands inside `protect_first_n`,
>   all of its calls are excluded by construction. A 10-file read that arrives as a
>   single batched assistant message at index 1 produces **0 candidates** no matter
>   how large the results are.
>
>   Corollary: an isolated short test session can essentially never exercise the
>   engine. Do not conclude "it never fires" from one — check the resolved knobs and
>   the message count first, via `get_status().jev_config` and `jev_last_skip`.

## 3. The Support files list is incomplete

The body's *Support files* section lists only `references/context-engine-api.md`.
Five files actually exist. Add the other four:

```
- `references/production-firing-diagnosis.md` — the original hunt; its
  "STILL UNRESOLVED" conclusion is superseded.
- `references/production-firing-resolved.md` — **the resolution**; read this one.
- `references/plugin-engine-implementation.md`
- `references/plugin-engine-corrections.md`
```

A reference nobody knows about is a reference nobody reads.

## Why this is a separate file

The curator's read-before-write guard requires the SKILL.md content to be loaded
**in the same turn with no intervening skill-tool call**, and a re-view of an
unchanged file returns `dedup: true, content_returned: false` — which does not
satisfy it. So: **immediately after the first `skill_view(SKILL.md)`, issue the
SKILL.md write as the very next call.** Deferring it to view a reference file, or
to write a new reference first, forfeits the write for that turn. One SKILL.md
write per skill per turn.
