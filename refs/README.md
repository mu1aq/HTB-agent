# refs/ — on-demand failure-mode references (epistemic, NOT playbooks)

These are the lazy-loaded detail layer: the core doctrine (`doctrine/*.md`) holds the hunt loop
plus a tiny **mode index**; the *remedy* for each recurring **failure mode** lives here and is
pulled in (pushed by the harness, or read by the solver) only when that mode is active. This keeps
the always-injected prompt lean without dropping any remedy.

**Governed by `doctrine/00-prime-directive.md` → "Failure-mode references are epistemic, not
procedural."** Two hard lines, enforced by `eval/selftest.sh` (the tripwire against playbook rot):

1. **Reasoning-signal keyed only.** A mode's detector may key on *your own reasoning process*
   (repetition, stall, journal drift, inconclusive evidence, breadth decay, budget, ceiling, idle),
   **never on the target** (port, service, version, banner, named fork). Target-keyed = playbook.
2. **Reasoning-corrections only.** A ref says *how to re-think*, never *what to run*. It must not
   name a CVE, an exploit/metasploit module, or a per-service command recipe. Generic
   environment-agnostic examples of *inventory* (e.g. "check identity/role/caps") are fine; a
   step list for a specific technology is not.

What refs do NOT cover: *which surface to enumerate next* and *which technique fits this target* —
those are live reasoning + research (`doctrine/20`), never a lookup.

## File contract (each `refs/<mode>.md`)

```
# <mode> — <one-line: the reasoning pathology this corrects>
trigger: <the reasoning signal that means you are in this mode>
correction: <how to re-think — the generalized epistemic move>
```

Keep each ref short (a screen or less). If a ref grows a technique, a tool invocation, or a
target-keyed trigger, the selftest fails — that is the tripwire telling you it has drifted into a
playbook. Fix the ref, don't suppress the check.

## Mode index

The core doctrine carries the index that points here. Its machine-checkable form is a fenced block:

```
MODES
  <mode>  detector: <reasoning-signal>  ref: refs/<mode>.md
```

`eval/selftest.sh` parses every `detector:` token and fails if it is not a reasoning-signal
(i.e. if a mode keys on the target). Build modes one at a time, each gated by `eval/score.py`.
