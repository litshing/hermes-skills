# Middleware and hooks — the behaviour-changing half of the plugin surface

Hooks **observe** what happened. Middleware **changes** what happens. Both are
registered from `register(ctx)` in a plugin's `__init__.py`, and both have
contracts where getting the return shape wrong is silently destructive.

Verified against `hermes_cli/plugins.py`, `hermes_cli/middleware.py`,
`docs/middleware/README.md`, and `docs/developer-guide/plugins/index.md`.

---

## 1. The four middleware kinds

```python
def register(ctx) -> None:
    ctx.register_middleware("tool_execution", on_tool_execution)
```

| Kind | Payload | Return shape | Purpose |
|---|---|---|---|
| `llm_request` | `request`, `original_request` | `{"request": {...}}` | Replace provider kwargs before execution |
| `tool_request` | `tool_name`, `args`, `original_args` | `{"args": {...}}` | Replace tool args before hooks, guardrails, approvals |
| `llm_execution` | `request`, `original_request`, `next_call` | any provider response | Wrap/replace the provider call |
| `tool_execution` | `tool_name`, `args`, `original_args`, `next_call` | any tool result | Wrap/replace the tool call |

Request middleware may also return trace fields:

```python
return {"request": updated, "source": "my-plugin", "reason": "why"}
```

Trace entries surface in later observer-hook payloads as `middleware_trace`.

Every callback also receives `telemetry_schema_version`
(`hermes.observer.v1`), `middleware_schema_version` (`hermes.middleware.v1`),
and runtime context: `session_id`, `task_id`, `turn_id`, `api_request_id`,
`provider`, `model`, `api_mode`, `tool_name`, `tool_call_id`.

Unknown kinds are stored but warned — a typo does not fail loudly.

---

## 2. ⚠️ The `None` trap: returning `None` from execution middleware breaks every tool call

The single most dangerous trap in the plugin surface. `hermes_cli/middleware.py`
`_run_execution_chain` ends with:

```python
call_kwargs = middleware_payload(**kwargs)
call_kwargs[payload_key] = payload
call_kwargs["next_call"] = next_call
try:
    return callback(**call_kwargs)        # ← the callback's return value IS the result
except _DownstreamExecutionError as exc:
    raise exc.original
except Exception as exc:
    logger.warning("Middleware '%s' callback %s raised: %s", ...)
    if next_succeeded:
        return next_result                # downstream already ran, preserve it
    if next_called:
        raise
    return call_at(index + 1, payload)    # ← only a RAISE is fail-open
```

Consequences:

- **Raising** before calling `next_call` is fail-open — the chain proceeds to the
  next middleware and the base runtime. Safe.
- **Returning `None`** without calling `next_call` does *not* pass through. That
  `None` becomes the tool result. A gate that early-returns `None` for tools it
  doesn't care about silently replaces the result of **every tool in the
  session** with `None` — and because the chain swallows nothing and logs
  nothing, it looks like the tools themselves broke.

### Correct delegation

```python
def on_tool_execution(**kwargs):
    next_call = kwargs.get("next_call")
    args = kwargs.get("args")
    if not callable(next_call):
        return None
    # Anything not judged is a pure pass-through — NEVER `return None` here.
    if kwargs.get("tool_name") != "memory" or not isinstance(args, dict):
        return next_call(args)

    try:
        verdict = decide(dict(args))
    except Exception as exc:                  # fail-open, always
        logger.warning("gate error, allowing call: %s", exc)
        verdict = None
    if verdict is not None:
        return verdict                        # deliberate short-circuit
    return next_call(args)
```

`next_call` rules:

- **Single-use per frame.** Calling it twice raises `RuntimeError` — that is a
  contract violation, not a retry.
- Call it **exactly once** unless intentionally short-circuiting.
- Short-circuiting by returning your own result *instead of* calling it is
  sanctioned ("unless it is intentionally short-circuiting execution"), and is
  the clean way to decline a call.
- If you call it and then raise during post-processing, the downstream result is
  preserved and the provider/tool is **not** run again.

### Picking the right kind for a gate

| Goal | Kind | Why |
|---|---|---|
| Rewrite args (paths, defaults, targets) | `tool_request` | `None` is genuinely safe — chain does `if not isinstance(result, dict): continue` |
| Decline/short-circuit a call, or replace its result | `tool_execution` | Only kind that can answer without executing |

`tool_request` runs **before** approval checks, so a rewritten path/command/URL is
what guardrails and approvals evaluate. That is a feature for normalisation and a
hazard for anything security-adjacent.

### Test against the real chain

The failure lives in host code, so a mocked chain cannot catch it:

```python
from hermes_cli.middleware import _run_execution_chain

out = _run_execution_chain("tool_execution", [my_callback], terminal,
                           tool_name="read_file", args={"path": "/tmp/x"},
                           original_args={"path": "/tmp/x"})
assert out == "read-file-output", f"tool result was swallowed: {out!r}"
```

Assert one ignored-tool shape per class of call the plugin skips (at minimum a
generic tool, the judged tool, and the tool's non-judged actions such as a read
vs a write).

---

## 3. Observer hooks (`register_hook`)

`ctx.register_hook(hook_name, callback)`. Unknown names warn but are stored, for
forward compatibility. The valid set:

```
api_request_error            post_api_request            pre_approval_request
gateway_platform_event       post_approval_response       pre_command
kanban_task_blocked          post_llm_call                pre_gateway_dispatch
kanban_task_claimed          post_tool_call               pre_llm_call
kanban_task_completed        pre_api_request              pre_tool_call
on_interim_message           pre_transcription            pre_verify
on_kanban_*                  subagent_start               subagent_stop
on_session_end               subagent_stop                transform_api_error_classification
on_session_finalize          on_session_reset             transform_llm_output
on_session_start             on_skill_lifecycle           transform_terminal_output
on_stream_delta              on_stream_end                transform_tool_result
on_stream_start
```

(authoritative list is `VALID_HOOKS` in `hermes_cli/plugins.py` — read it rather
than trusting this transcription, which is alphabetical-ish by accident)

Two ordering facts worth knowing:

- `pre_llm_call` is **inject-only** by design: it appends to the user message and
  never rewrites the message list, to preserve the prompt-cache prefix. Use it to
  add guidance; it cannot remove or replace context.
- The tool-call sequence is: parse/coerce args → `tool_request` middleware →
  availability checks, observer block directives, guardrails, approvals →
  `tool_execution` middleware → `post_tool_call` → `transform_tool_result`.

`transform_tool_result` and `transform_llm_output` are the cheapest way to
post-process output without owning execution.

---

## 4. Other registration points on `ctx`

```
register_context_engine(engine)     # one only; replaces compaction policy
register_memory_provider(provider)  # observe turns without owning anything
register_tool(...)                  # add a tool (tool OVERRIDE is privileged)
register_command(name, handler)     # slash/CLI command
register_system_prompt_section(id, content, *, position="after_memory", max_chars=N)
register_web_search_provider(...)   register_image_gen_provider(...)
register_tts_provider(...)          register_transcription_provider(...)
register_platform(...)              register_redaction_patterns(patterns)
register_auxiliary_task(...)        register_secret_source(source)
emit(event, payload) / subscribe(event, callback)   # plugin event bus
```

### `register_system_prompt_section`

Frozen into each **new** session prompt (bounded by `max_chars`, default
`DEFAULT_SYSTEM_PROMPT_SECTION_MAX_CHARS`). Only `position="after_memory"` is
valid. Content may be a string or a callable receiving a read-only session-info
mapping. Section ids must be 1–128 lowercase chars of `[a-z0-9._-]`; duplicate
ids raise.

This is the right home for session-scoped guidance: it is written once per
session, so it costs nothing per turn and cannot break the prompt-cache prefix
mid-conversation. Prefer it over a per-turn `pre_llm_call` injection when the
content does not need the latest turn.

### `register_tool` and the tool-override capability

Enabling a plugin prompts for tool-override permission, default **off**:

```
Allow this plugin to replace built-in tools (e.g. shell_exec, write_file)?
  Grant it?  <plugin> may not override built-in tools. Re-run
  `hermes plugins enable <plugin> --allow-tool-override` to grant this later.
```

Leave it off unless the plugin genuinely intercepts built-in tools — middleware is
usually the better shape because it composes with other plugins instead of
replacing the tool outright. Overriding a tool means reimplementing its behaviour.

---

## 5. Enablement and blast radius

Middleware and hooks only run for **enabled** plugins
(`hermes plugins enable <name>`) — see the "Discovery is not activation" failure
mode in the parent SKILL.md.

Because middleware callbacks sit in the hot path of every request or every tool
call:

- keep the callback's non-judged path to a single `next_call(args)` and nothing else;
- never do I/O, network, or blocking work on a path you don't intend to judge;
- guard shared state with a lock — callbacks may arrive on a pooled daemon thread;
- log every failure path, because fail-open means a broken callback is
  indistinguishable from a callback that chose to do nothing.
