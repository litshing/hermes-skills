# Making a probabilistic decision gate trustworthy

A **decision gate** is a component that sits in a pipeline, asks a cheap model for a
probability, and then spends money, deletes data, or declines an action on the strength of
it. Jev/TypeSafe (`references/jev-system-one-protocol.md`) is one such decider, but every
lesson here is model-agnostic and applies to any "score N items, act on the scores" step.

These are the failure modes that survive a green test suite. All were hit, diagnosed, and
fixed in one session; none of them throw.

---

## 1. Calibration: never put a threshold inside the natural cluster

Measured, on real data:

```
8 surviving items scored  0.46  0.46  0.48  0.48  0.48  0.49  0.49  0.53
configured floor          0.50
result                    nothing selected, every time
```

A re-run of a *single* item from that batch, on its own, came back `0.53` — it had scored
`0.48` in the batch. So run-to-run variance on the same input is roughly **±0.05**, and the
floor was sitting exactly where the items land. That is not a gate, it is a coin flip with
extra steps.

Before wiring a threshold:

- **Look at the distribution first.** Score a batch, print min/max, and only then pick a
  floor. If the scores cluster, an absolute floor inside the cluster is meaningless.
- **Put the floor clear of the cluster**, or use a **rank-based** selection ("top N, with a
  low sanity floor to exclude obvious junk") instead of a pass/fail test. Ranking is robust
  to a few hundredths of noise; an absolute test is not.
- **Record and surface the distribution** on every run (min, max, kept count, floor). A
  knife-edge is invisible without it.
- **Distinguish a miscalibrated threshold from a wrong model.** In the case above the model
  was *right* — eight mediocre lots genuinely were borderline; the comment "all read as
  borderline rather than actionable" was a correct answer. The defect was the threshold and
  the silent output, not the judgement.

Corollary for cheap-but-not-free decisions: two thresholds usually beat one. A permissive
one for the common case and a strict one for the destructive case, with the middle left to
the caller. See §6.

---

## 2. Payload honesty: do not filter out the zeros

```python
return {k: v for k, v in state.items() if v not in (None, "", [], 0)}   # ✗
```

Dropping `0` throws away the most informative field in many payloads — `0 bids`,
`0 photos analysed`, a zero opening bid. In an auction pipeline "nobody has bid on this" is
precisely the signal the gate exists to catch, and the filter deletes it before the decider
ever sees it.

```python
return {k: v for k, v in state.items() if v not in (None, "", [])}      # ✓
```

Decide what "absent" means once: `None`, `""` and empty containers are absent; **`0` and
`False` are evidence.** The same reasoning applies to config readers — see §5.

---

## 3. Memo integrity: key on the payload, not only on an id

Caching is mandatory (a per-turn hook will otherwise re-bill for identical input), but a
cache key built from an id is only as good as the id's presence.

Observed failure: two unrelated items were judged, neither carrying an id. Both keys
collapsed to `photo||v1`, so the second item silently **reused the first item's verdict**.
The tell was suspiciously identical scores for dissimilar inputs:

```
souvenir eggshell cup   p=0.11
18K Tiffany gold ring   p=0.11     ← identical, and wrong
```

Identical probabilities across genuinely different inputs is the signature of a cache
collision, not of a decisive model. After keying on the payload instead:

```
souvenir eggshell cup   p=0.12
18K Tiffany gold ring   p=0.73
```

```python
if stable_id:
    key = f"photo|{stable_id}|v1"
else:
    key = f"photo|noid:{digest(payload)}|v1"    # hash the evidence itself
```

Other rules that follow:

- **Version the key** (`|v1`). Bump it whenever the question text or the payload shape
  changes, or stale verdicts judged under different instructions get reused silently.
- A cached answer must never be able to *delete* something the live answer wouldn't. Prefer
  a cache miss (re-ask) over a cache guess on a destructive path.
- **Assert distinctness in a test**: two different payloads without ids must produce two
  requests. This is the regression that catches the collision class.

---

## 4. Threshold direction must be the cheap-wrong direction

State the default explicitly in code and in a comment, and pick the direction whose failure
is cheapest:

| Gate | Permissive default | Why |
|---|---|---|
| Skip a paid step | **spend** (run it) | A missed value call costs more than one credit |
| Reject a write | **allow** (write it) | The user has to notice and re-state a lost preference |
| Delete context | **keep** | Deletion is unrecoverable; a re-read is not |

Then set the *action* threshold with margin on the safe side — e.g. "decline only when the
probability of being wrong is clearly low", not at the midpoint of the plausible range.

---

## 5. Unknown config keys must be visibly ignored

```python
cfg.update(supplied)                                  # ✗ absorbs typos
for k, v in supplied.items():
    if k in cfg and v is not None: cfg[k] = v         # ✓ known keys only
```

A typo (`photo_skip_beow`) absorbed by a blind `update` sits in the dict *looking*
configured while the real default stays in force — a misconfiguration that presents as "the
threshold isn't working". Accept only known keys, treat only `None`/unparseable as unset
(never `or default`, which rewrites an explicit `0`), and add a one-line regression test for
each.

---

## 6. Output honesty: an empty result must be rendered, not omitted

Logging the failure path is necessary but **not sufficient**. The end user reads the
rendered output, not the log, and a gate that produces nothing is indistinguishable from a
gate that is broken:

```
## 🎯 Today's shortlist

_Nothing cleared the bar — best p=0.49 vs floor 0.50. All 8 surviving lot(s) read as
borderline rather than actionable; the full list above is the complete picture._
```

Rules:

- Expose a **stats record** from the gate (candidates, judged, kept, floor, min/max, and
  whether the request failed at all), so the caller can render *why* it is empty.
- **Three distinct empty states, three distinct messages:** nothing to judge / judged and
  nothing qualified / the request failed. Collapsing them into "nothing" is the bug.
- A failed request that leaves behaviour unchanged should say so in one line — otherwise a
  quietly degraded run is read as a clean one.

---

## 7. Checklist before trusting a gate

- [ ] Distribution measured; floor(s) placed clear of the cluster, not inside it
- [ ] `0` and `False` survive into the payload; only `None`/`""`/`[]` are dropped
- [ ] Memo keys are versioned and payload-derived when no stable id exists
- [ ] Regression test: two id-less payloads ⇒ two requests
- [ ] Unknown config keys ignored; explicit `0` honoured; each has a test
- [ ] Permissive default is the cheap-wrong direction, named in code
- [ ] Empty, failed, and nothing-qualified are three separate rendered outcomes
- [ ] Every failure path leaves the pre-gate behaviour intact (fail-open) and is counted
