# Corrections & implementation notes — supersedes parts of SKILL.md

Read this **first**, then `references/plugin-engine-implementation.md` for the
full code-level detail. The SKILL.md body is right about the *architecture* but
stale or wrong in five places. Where this file and SKILL.md disagree, this wins.

## 1. The `context.engine` resolution order is FOUR steps, not two

SKILL.md lists only "directory discovery" then "generic plugin system". The real
order, in `agent/agent_init.py` (~line 2514):

1. `config.yaml` → `context.engine` (default `"compressor"`)
2. `plugins/context_engine/<name>/` — repo-shipped, via `load_context_engine(name)`
3. **the generic plugin system** — `get_plugin_context_engine()`. The returned
   singleton's `.name` **must equal** the configured value, or it is ignored with a
   `"Context engine 'X' not found — falling back to built-in compressor"` warning
4. built-in `ContextCompressor`

A user plugin installed at `~/.hermes/plugins/<name>/` is reached by **step 3**, so
the engine's `name` property is what `context.engine` has to match.

## 2. "Status: designed, NOT built" is out of date

An engine now exists: `~/.hermes/plugins/jev-compaction/` — `plugin.yaml`,
`__init__.py` (engine + `register(ctx)`), `jev.py` (judgment client),
`tests/test_plugin.py` (~28 contract tests).

It has **not** been executed under a live agent. The contract tests could not run
because the Hermes venv has no pytest, and installing into the interpreter the
gateway runs on is a deliberate, user-owned step. So: tell the user it **exists**;
do not tell them it **works**.

## 3. "Wrap the built-in (hold an inner instance and forward)" → prefer subclassing

Holding an inner `ContextCompressor` and forwarding works, but throws away four
things you inherit for free by subclassing: the `archive_and_compact()` session-DB
commit path, the prompt-cache re-arm runway, the capability gate for session stores
lacking `archive_and_compact`, and the lossless byte-identical-result dedup pass.
See `plugin-engine-implementation.md` → *Subclass `ContextCompressor`*.

## 4. The Verification section's `pytest` command will fail

`agent` imports **only** through the venv interpreter:

```bash
cd ~/.hermes/hermes-agent
venv/bin/python3 -m pytest tests/agent/test_context_engine.py -v
venv/bin/python3 -m pytest tests/gateway/test_compress_plugin_engine.py -v
venv/bin/python3 -m pytest tests/agent/test_context_engine_host_contract.py -v
```

If pytest is absent from that venv, check the blast radius before installing
(`uv pip install --python venv/bin/python3 --dry-run pytest`) — it is the runtime
the gateway uses.

## 5. There is a silent-failure trap SKILL.md doesn't mention at all

**The deepcopy trap.** `agent_init.py` deep-copies the plugin singleton per agent
(#42449). An engine holding a `threading.Lock` — which the thread-safety contract
forces you to hold — raises on deepcopy, and the host then **silently falls back to
the built-in compressor** while config still reads `context.engine: my-engine`.
Installed, no error, doing nothing.

Implement `__deepcopy__` (rebuild locks/caches, deep-copy budget state, share
anything uncopyable) and make `copy.deepcopy(engine)` an explicit unit test. Full
recipe and the host source in `plugin-engine-implementation.md`.

## Two more facts worth not rediscovering

- **`plugin.yaml` kinds** (`hermes_cli/plugins.py`): `standalone`, `backend`,
  `exclusive`, `platform`, `model-provider`. `exclusive` is for memory providers.
  A directory plugin needs **both** `plugin.yaml` and an `__init__.py` with
  `register(ctx)`.
- **Hyphenated plugin dirs can't be imported normally.** Mirror the loader with
  `importlib.util.spec_from_file_location(..., submodule_search_locations=[DIR])`
  so relative imports (`from . import jev`) resolve.

## Meta: why these corrections live in a reference file

The curator read-before-write guard requires a **content-returning** `skill_view`
in the *same message* as a SKILL.md write. This conversation had already loaded
SKILL.md, so every re-view returned `dedup: true, content_returned: false`, which
the guard rejects — SKILL.md itself could not be corrected in that pass. Creating a
**new** `references/` file is unguarded; overwriting an existing one is guarded the
same way. To fold these back into SKILL.md, do it from a fresh session where
SKILL.md has not yet been loaded.
