# Memoisation correctness and negative results in decision gates

Two failure modes that both present as "the model is bad at judging", and both
actually belong to the code around the model. Companion to
`trustworthy-decision-gates.md` (which covers designing the question) — this file
covers the plumbing *around* a cached judgement.

---

## 1. The memo key must be derived from the INPUTS, not from an id

Gates that call a paid API build an in-process memo so an unchanged item is never
re-judged. The dangerous version keys it on a record id that may be **absent**: two
different items with no id then share one cache entry, and the second item silently
receives the first one's verdict. No error, no log — just a wrong answer.

```python
# WRONG — every id-less item collides on the same entry
cache_key = f"verdict|{item.get('id') or ''}|v1"

# RIGHT — fall back to a digest of the evidence the verdict was based on
import hashlib, json

def _evidence_digest(item, *evidence):
    blob = json.dumps({"item": item, "evidence": evidence},
                      ensure_ascii=False, sort_keys=True, default=str)
    return hashlib.sha1(blob.encode("utf-8", errors="replace")).hexdigest()[:16]

item_id = str(item.get("id") or "")
cache_key = (f"verdict|{item_id}|v1" if item_id
             else f"verdict|noid:{_evidence_digest(item, evidence)}|v1")
```

### How you actually catch it

**Identical scores across obviously-different inputs are the signature of a cache
collision — not of a model that cannot discriminate.** In the session that found
this, a souvenir cup and a gold designer ring both scored *exactly* `0.11`. The
temptation is to conclude the model is insensitive; the correct first move is to
inspect the cache.

```python
def test_id_less_items_do_not_share_a_cache_entry():
    calls = []
    with patched(tg, "_post", _fake_post(counter=calls)):
        run_gate({"title": "souvenir cup"}, cfg)
        run_gate({"title": "18K gold ring"}, cfg)
    assert len(calls) == 2, "an id-less item reused another item's cached verdict"
```

Once the key was fixed, the same two items scored `0.12` and `0.73` — the model had
been fine the whole time.

### Related: test the transport, not the wrapper

When a test needs to exercise caching, patch the **transport layer** (e.g. the
`_post` that performs the HTTP call), not the wrapper that reads-and-writes the
cache. Patching the wrapper removes the very cache write you are trying to test, so
the test passes for the wrong reason and hides the bug above. If a cache test never
observes a cache *hit*, it is not testing the cache.

---

## 2. A negative result must be reportable

Fail-open plus a silent no-op makes "found nothing to do" and "is broken"
indistinguishable to the user. If a gate's output is user-visible (a report
section, a list, a count), record *why* it was empty and surface it.

```python
LAST_RUN: dict = {}                     # module-level so the caller can read it

# ... at the end of the gate:
LAST_RUN.update({
    "candidates": len(items),
    "judged": len(scored),
    "kept": len(picked),
    "floor": keep,
    "max_p": scored[0][1] if scored else None,
    "min_p": scored[-1][1] if scored else None,
})
```

Then the caller renders a reason instead of nothing:

```
## Today's shortlist
_Nothing cleared the bar — best p=0.49 vs floor 0.50. All 8 surviving lot(s) read
as borderline rather than actionable; the full list above is the complete picture._
```

An empty result that explains itself is worth far more than a silent one, and it is
also the diagnostic you need later: the numbers above showed every score clustered
at 0.46–0.49 against a `0.5` floor — i.e. the **threshold was sitting on the noise**
(one item scored 0.53 on a solo call and 0.48 in a batch, ±0.05 run-to-run drift).
That is a calibration finding, and it is invisible without the distribution.

**Corollary:** when a gate returns nothing, do not assume the gate is broken.
Check whether the answer is legitimately "nothing qualified" — and report the
distribution either way, so the reader can tell which it was.
