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

### Adding a box
Append a row to `boxset.json` **and** keep a real run under `runs/<name>/`; re-snapshot the
baseline. Base names are matched ignoring `.bak.<ts>` archive suffixes, and `best` is the best
outcome ever seen for that box while `current` is the canonical (non-`.bak`) run — which is how
the scorecard shows Nimbus as `current=failed / best=solved` (a within-repo regression).

---

## Backlog — deliberately deferred behind this eval

The red-team of the system named five moves (A–E). **A (this eval)** and **B (doctrine diet)**
are done. The rest are **frozen until the eval produces numbers**, because shipping more
unmeasured mechanism is the exact anti-pattern that motivated `eval/` in the first place. They
land one at a time, each with a before/after on the box-set scorecard:

- **C — mechanical capability tools (the real lever on a fixed 4.8 ceiling).** Not playbooks
  (which vector to use — forbidden) but *hands* (one mechanical step, done reliably): a verified
  SigV4/SQS request shaper, pwncat/impacket wrappers, protocol clients. The Nimbus crux
  (`SendMessage` queue-URL/SigV4 format) was a capability gap no amount of doctrine could close.
- **D — push feedback + applied verification.** The auditor already pushes; extend it from
  "read this file" to injecting the caught world-model error into the next tool call, and verify
  the correction was actually applied.
- **E — parallel *investigation* (not just parallel recon).** Concurrent deep-investigation
  sub-agent threads on independent surfaces, each reporting only confirmed facts.

Each is gated: implement → run the affected boxes → `score.py` must show no regression and,
ideally, a real improvement, before it is kept.
