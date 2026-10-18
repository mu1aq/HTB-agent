# eval/ — the measurement layer

> **Why this exists.** The system had been improving by *adding mechanisms* (guard,
> auditor, surrender gate, surfaces, recall, nudges, §2–§5 doctrine …) with **no feedback
> loop**. The ratio "mechanisms added ÷ boxes actually solved end-to-end with them" was
> dangerously high, and the *only* way a regression was ever caught was a human watching a
> live hunt — that is how a clobbered `PATH` and an empty-journal seed both shipped. You
> cannot improve what you cannot measure. `eval/` is that measurement, and **it is the
> gate**: no new governance/doctrine mechanism lands until it stands.

Two layers, both cheap and deterministic — neither needs an HTB token, the VPN, or a box.

## 1. `selftest.sh` — the fast wiring loop (the regression catcher)

```bash
./eval/selftest.sh        # all invariants, exit non-zero on any failure
./eval/selftest.sh -v     # verbose
```

Asserts the launcher's load-bearing invariants by calling the **real** functions
(`rc2_scaffold`, `rc2_build_sysprompt`, `rc2_pin_model`), not by reimplementing them:

- every shell script parses (`bash -n`) and every python script compiles;
- **no `PATH=` assignment clobbers `$PATH`** — the exact shape of the shipped PATH bug;
- the 7 doctrine files are present, build in numeric order, and the system prompt is
  **byte-stable** across builds (the 1h prompt-cache prefix depends on this);
- **doctrine has no hardcoded cross-repo absolute paths** — the `cp`-contamination bug: a
  doctrine copied from `redcatN` still pointing the agent back into `redcatN`. Doctrine must
  be repo-agnostic (relative paths via the symlinked `scripts/` + `reference/` dirs);
- the scaffold seeds `worldmodel/hypotheses/journal/ledger` **non-empty**, with a real
  journal `START` entry — the empty-journal bug;
- the **opus→4.8 safety pin** holds (`opus`, `claude-opus-5-*` → `claude-opus-4-8`;
  sonnet/haiku pass through) and no sub-agent frontmatter selects an uncapped opus-5+;
- all 5 sub-agents have `name:`+`model:` frontmatter; `.env` is not tracked by git.

**Run it before every change to `lib/`, `hunt`, `doctrine/`, or `.claude/agents/`.** A red
here is a regression that used to require a human to notice.

## 2. `score.py` + `boxset.json` + `baseline.json` — the box-set scorecard

```bash
python3 eval/score.py                 # scorecard + regression diff vs baseline
python3 eval/score.py --json          # machine-readable
python3 eval/score.py --set-baseline  # snapshot current state as the new baseline
```

Turns the artifacts a hunt already drops (`runs/<box>/failure_analysis.json`, `flags.txt`)
into a **reproducible pass/fail scorecard** against a fixed box set, and **diffs it against a
committed baseline** so a `solved → failed` regression is caught by a command. It does *not*
run boxes — `./hunt <box>` does; this **scores the result** and records where/why each run
died (the `failure_analysis` death-category + whether user/root flags landed).

- `boxset.json` — the fixed set. `expect: "solved"` = demonstrably solved ≥ once, so it must
  stay solvable; `expect: "unknown"` = not yet solved, informational. `crux` = the decisive
  step, for reading a death.
- `baseline.json` — the committed reference snapshot (`runs/` is gitignored, so the baseline
  is the durable record, like `triage/`). Re-snapshot it deliberately when state legitimately
  changes.
- `scorecard.json` — generated per-machine (gitignored).

Exit non-zero on a regression vs baseline **or** an unmet box-set expectation — so it drops
straight into CI or a pre-push check.

**Death-mode distribution (#0).** Each current run is classified — by a transparent, ordered rule
over the metrics a run already drops — into *where it died*: `coverage-gap / capability-gap /
tunneling / window-exhaustion / false-verify / unclear`. The distribution is what **aims** the next
investment (fix the tallest non-solved bar). The signals are coarse today (often all-zero on a
loss), so the classifier falls through to `unclear` rather than guess — and that `unclear` is itself
the finding: cleanly separating capability-gap from coverage needs an *inconclusive-ratio* signal we
do not yet log. Classifier rules live at the top of `score.py`.

### Adding a box
Append a row to `boxset.json` **and** keep a real run under `runs/<name>/`; re-snapshot the
baseline. Base names are matched ignoring `.bak.<ts>` archive suffixes, and `best` is the best
outcome ever seen for that box while `current` is the canonical (non-`.bak`) run — which is how
the scorecard shows Nimbus as `current=failed / best=solved` (a within-repo regression).

---

## Backlog — deliberately deferred behind this eval

The red-team named five moves (A–E). Status:

- **A — eval / measurement.** Done (this dir): selftest + box-set scorecard + **death-mode (#0)**.
- **B — doctrine diet.** Done: hardcoded-path generalization + compressed 10-hunt-loop.
- **Failure-mode refs + tripwire.** Scaffolded (`refs/`, `doctrine/00`, selftest lint) — the
  guardrail is in before the refs; modes land one at a time, each eval-gated.
- **C — capability library (#1).** Framework landed: `capabilities/` (mechanical *hands*, reused
  across runs), `doctrine/30` save/reuse rule, scaffold symlink, selftest tripwire. Runs populate
  it; it is how a fixed 4.8 compounds. (The Nimbus `SendMessage` SigV4/queue-URL crux is the kind
  of mechanical hand it is meant to hold.)
- **Verification hand (#2).** Done: `scripts/prove.sh` (deterministic flag-realness + shell/identity
  proof), wired into `doctrine/10` VERIFY, functional selftest. Cuts the false-verify loss.

Still **frozen until the numbers call for them** (shipping unmeasured mechanism is the anti-pattern
`eval/` exists to stop):
- **D — push feedback (applied).** Extend the auditor push from "read this file" to injecting the
  caught error into the next tool call + verifying the correction landed.
- **E — parallel *investigation*.** Reframed (see the session's design notes): the real pain is
  **breadth decay** (a memory/scheduling fix, single loop), not concurrency; true multi-solver
  concurrency is heavy and token-budget-multiplying — gate it on the death-mode distribution.

Everything is gated: implement → run the affected boxes → `score.py` must show no regression (and
ideally a real improvement) before it is kept.
