#!/usr/bin/env python3
"""
eval/score.py — the box-set scorecard + regression diff (critique "A": measurement).

Turns the artifacts a hunt already drops on disk (runs/<box>/failure_analysis.json,
flags.txt) into a REPRODUCIBLE pass/fail scorecard against a fixed box set
(eval/boxset.json), and diffs it against a committed baseline (eval/baseline.json)
so a solved->failed regression is caught by a command, not by a human watching a
live run. It does NOT run boxes — `./hunt <box>` does that; this scores the result.

  python3 eval/score.py                 # print scorecard + regression diff vs baseline
  python3 eval/score.py --json          # machine-readable scorecard to stdout
  python3 eval/score.py --set-baseline  # snapshot current scorecard as the new baseline
  exit code: 0 = no regressions vs baseline, 1 = a box regressed (or a box-set expectation unmet)
"""
import json, os, re, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS = os.path.join(ROOT, "runs")
BOXSET = os.path.join(ROOT, "eval", "boxset.json")
BASELINE = os.path.join(ROOT, "eval", "baseline.json")
SCORECARD = os.path.join(ROOT, "eval", "scorecard.json")

RANK = {"solved": 3, "partial": 2, "failed": 1, "empty": 0, "unknown": 0, None: 0}
BAK_RE = re.compile(r"\.bak\.\d+$")
CEIL = int(os.environ.get("RC2_CEIL", "800"))  # experiment hard-stop (lib/env.sh default)

# death-mode taxonomy (#0): a transparent, ORDERED mapping from the metrics a run already drops to
# where it died. The signals in failure_analysis.json are coarse (often all-zero even on a loss), so
# the classifier is deliberately conservative and falls through to 'unclear' rather than guess. The
# gap it exposes — telling capability-gap from coverage from tunneling needs an INCONCLUSIVE signal
# we do not yet log — is itself the finding that motivates the next instrument.
def death_mode(outcome, steps, fa, bad_flags):
    if outcome == "solved":
        return "solved"
    s = steps or 0
    if bad_flags > 0:
        return "false-verify"               # recorded a flag the API rejected
    if s >= 0.9 * CEIL:
        return "window-exhaustion"          # ran up against the experiment ceiling / budget
    if fa.get("max_repeat", 0) >= 4 or fa.get("identical_result_stalls", 0) > 0 or fa.get("repeated_actions", 0) >= 5:
        return "tunneling"                  # ground the same action with no evidence movement
    if fa.get("timeouts", 0) > 0 or fa.get("error_rate_pct", 0) >= 15 or fa.get("tool_errors", 0) >= 10:
        return "capability-gap"             # the mechanism kept failing to execute
    if fa.get("confirmed_hypotheses", 0) == 0 and fa.get("phase_transitions", 0) <= 1:
        return "coverage-gap"               # never established a foothold / never moved phase
    return "unclear"                        # made progress, no clear pathology signal (needs richer signal)


def base_name(dirname):
    return BAK_RE.sub("", dirname)


def load_run(d):
    """Read one run dir -> {outcome, difficulty, steps, dur, death, user_flag, root_flag}."""
    fa = os.path.join(d, "failure_analysis.json")
    out = {"outcome": "unknown", "difficulty": None, "steps": None,
           "dur": None, "death": None, "mode": "unknown", "user": False, "root": False}
    fa_inner = {}
    if os.path.isfile(fa):
        try:
            j = json.load(open(fa))
            out["outcome"] = j.get("outcome") or "unknown"
            out["difficulty"] = j.get("difficulty")
            out["steps"] = j.get("steps")
            out["dur"] = j.get("duration_min")
            fa_inner = j.get("failure_analysis") or {}
            out["death"] = fa_inner.get("primary_category")
        except Exception as e:
            out["outcome"] = "unknown"
            out["death"] = f"unparseable:{e}"
    # false-verify signal: a flag the lab API rejected (hook records kind:bad:<flag> in .submitted)
    bad_flags = 0
    sub = os.path.join(d, "logs", ".submitted")
    if os.path.isfile(sub):
        try:
            bad_flags = sum(1 for ln in open(sub, errors="ignore") if "kind:bad" in ln)
        except Exception:
            pass
    out["mode"] = death_mode(out["outcome"], out["steps"], fa_inner, bad_flags)
    ft = os.path.join(d, "flags.txt")
    if os.path.isfile(ft):
        txt = open(ft, errors="ignore").read()
        out["user"] = "user=" in txt
        out["root"] = "root=" in txt
    return out


def collect():
    """Group every run dir under its base box name."""
    groups = {}
    if not os.path.isdir(RUNS):
        return groups
    for d in sorted(os.listdir(RUNS)):
        full = os.path.join(RUNS, d)
        if not os.path.isdir(full):
            continue
        groups.setdefault(base_name(d), []).append((d, full))
    return groups


def score():
    boxset = json.load(open(BOXSET))["boxes"]
    groups = collect()
    rows = []
    for box in boxset:
        name = box["name"]
        runs = groups.get(name, [])
        # canonical (non-.bak) run is "current"; else the lexically-last .bak (timestamps sort)
        current_dir = next((f for (d, f) in runs if not BAK_RE.search(d)), None)
        if current_dir is None and runs:
            current_dir = sorted(runs, key=lambda x: x[0])[-1][1]
        cur = load_run(current_dir) if current_dir else load_run("/nonexistent")
        # best outcome ever observed across all runs of this box
        best = max((load_run(f) for (d, f) in runs),
                   key=lambda r: RANK.get(r["outcome"], 0), default=cur)
        expect = box.get("expect", "unknown")
        meets = (expect != "solved") or (RANK.get(best["outcome"], 0) >= RANK["solved"])
        regressed_within = RANK.get(cur["outcome"], 0) < RANK.get(best["outcome"], 0)
        rows.append({
            "box": name, "difficulty": box.get("difficulty") or cur["difficulty"],
            "expect": expect, "runs": len(runs),
            "current": cur["outcome"], "best": best["outcome"],
            "death": cur["death"], "mode": cur["mode"], "steps": cur["steps"], "dur_min": cur["dur"],
            "user_flag": cur["user"], "root_flag": cur["root"],
            "meets_expect": meets, "regressed_within_repo": regressed_within,
            "crux": box.get("crux", ""),
        })
    return rows


def diff_baseline(rows):
    """Compare current scorecard to committed baseline -> regressions / improvements."""
    if not os.path.isfile(BASELINE):
        return None
    base = {r["box"]: r for r in json.load(open(BASELINE))["boxes"]}
    regress, improve = [], []
    for r in rows:
        b = base.get(r["box"])
        if not b:
            continue
        now, was = RANK.get(r["current"], 0), RANK.get(b.get("current"), 0)
        if now < was:
            regress.append((r["box"], b.get("current"), r["current"]))
        elif now > was:
            improve.append((r["box"], b.get("current"), r["current"]))
    return {"regress": regress, "improve": improve}


def fmt_table(rows):
    w = "{box:<20} {difficulty:<7} {expect:<8} {cur:<9} {flags:<6} {mode}"
    out = [w.format(box="BOX", difficulty="DIFF", expect="EXPECT", cur="CURRENT",
                    flags="FLAGS", mode="DEATH-MODE"),
           "-" * 72]
    for r in rows:
        flags = ("U" if r["user_flag"] else "-") + ("R" if r["root_flag"] else "-")
        mark = "" if r["meets_expect"] else "  <- UNMET"
        reg = "  <- regressed-vs-best" if r["regressed_within_repo"] else ""
        out.append(w.format(box=r["box"], difficulty=str(r["difficulty"] or "?"),
                            expect=r["expect"], cur=r["current"],
                            flags=flags, mode=str(r["mode"] or "")) + mark + reg)
    return "\n".join(out)


def fmt_distribution(rows):
    """#0: where the box set dies — the signal that aims where to invest next."""
    from collections import Counter
    c = Counter(r["mode"] for r in rows)
    order = ["solved", "coverage-gap", "capability-gap", "tunneling",
             "window-exhaustion", "false-verify", "unclear", "unknown"]
    lines = ["death-mode distribution (current run per box — where we lose):"]
    for m in order:
        if c.get(m):
            lines.append(f"  {m:<18} {c[m]}")
    losses = [m for m in c if m not in ("solved",)]
    if losses:
        lines.append("  invest where the tallest non-solved bar is; 'unclear' = our signals are"
                     " too coarse here (needs an inconclusive-ratio signal we do not yet log).")
    return "\n".join(lines)


def main():
    rows = score()
    if "--set-baseline" in sys.argv:
        json.dump({"boxes": rows}, open(BASELINE, "w"), indent=2)
        print(f"baseline written: {BASELINE}  ({len(rows)} boxes)")
        return 0
    json.dump({"boxes": rows}, open(SCORECARD, "w"), indent=2)
    if "--json" in sys.argv:
        print(json.dumps({"boxes": rows}, indent=2))
        return 0

    print("redcat box-set scorecard   (runs/ is live; baseline is the committed record)\n")
    print(fmt_table(rows))
    print()
    print(fmt_distribution(rows))
    unmet = [r["box"] for r in rows if not r["meets_expect"]]
    d = diff_baseline(rows)
    print()
    if d is None:
        print("no baseline yet — run `python3 eval/score.py --set-baseline` to record one.")
    else:
        if d["regress"]:
            print("REGRESSIONS vs baseline:")
            for box, was, now in d["regress"]:
                print(f"  {box}: {was} -> {now}")
        if d["improve"]:
            print("improvements vs baseline:")
            for box, was, now in d["improve"]:
                print(f"  {box}: {was} -> {now}")
        if not d["regress"] and not d["improve"]:
            print("no change vs baseline.")
    # exit non-zero on a regression vs baseline, or an unmet box-set expectation
    bad = (d and d["regress"]) or unmet
    if unmet:
        print(f"\nbox-set expectations UNMET: {', '.join(unmet)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
