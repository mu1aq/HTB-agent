# capabilities/ — the library of mechanical hands (reused across runs)

On a fixed model, the one thing that can compound over time is the **environment around it**. This
is that store: verified, reusable *mechanical* tools a hunt builds once and every later hunt reuses,
so the agent's hands get better even though its reasoning does not.

**Governed by `doctrine/00-prime-directive.md` (the epistemic/procedural line) — this is "hands",
never a playbook.** A capability:

- **executes one mechanical step** — signs / builds / parses / frames / drives an oracle / assembles
  a gadget. It does *work*, it does not *decide*.
- is described by **what it does mechanically**, never by a target, a vector, or "when to use it".
  *"sign an arbitrary HTTP request with SigV4 given creds+params"* ✓ — *"exploit SQS on Nimbus"* ✗.
- **never names a CVE, an exploit/metasploit module, or a per-service recipe.** If it would, it is an
  exploit for one box, not a reusable hand — keep that in that run's `exploit/`, not here.

Deciding *which* capability to reach for, and *what vector* fits the target, is live reasoning
(`doctrine/10`,`20`) — never a lookup here. `eval/selftest.sh` lints `INDEX.md` for drift across this
line (CVE/msf markers), the same tripwire that guards `refs/`.

## How it is used (`doctrine/30` → Build what doesn't exist)

- **Read `INDEX.md` before building a primitive** — reuse beats rewrite.
- **Promote a working primitive** from a run's `tools/` by copying the script here and adding one
  `INDEX.md` line. Scripts are untrusted like any tool: read before run, pass paths as args.
- `capabilities/` is symlinked into every run dir, so address it relative: `capabilities/<file>`.

## INDEX format

```
path | mechanical action (what it signs/builds/parses) | inputs -> output | from-run
```
