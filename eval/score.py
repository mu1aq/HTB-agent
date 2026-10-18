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


def base_name(dirname):
    return BAK_RE.sub("", dirname)


def load_run(d):
    """Read one run dir -> {outcome, difficulty, steps, dur, death, user_flag, root_flag}."""
    fa = os.path.join(d, "failure_analysis.json")
    out = {"outcome": "unknown", "difficulty": None, "steps": None,
           "dur": None, "death": None, "user": False, "root": False}
    if os.path.isfile(fa):
        try:
            j = json.load(open(fa))
            out["outcome"] = j.get("outcome") or "unknown"
            out["difficulty"] = j.get("difficulty")
            out["steps"] = j.get("steps")
            out["dur"] = j.get("duration_min")
            out["death"] = (j.get("failure_analysis") or {}).get("primary_category")
        except Exception as e:
            out["outcome"] = "unknown"
            out["death"] = f"unparseable:{e}"
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
            "death": cur["death"], "steps": cur["steps"], "dur_min": cur["dur"],
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
    w = "{box:<20} {difficulty:<7} {expect:<8} {cur:<9} {best:<9} {flags:<6} {death}"
    out = [w.format(box="BOX", difficulty="DIFF", expect="EXPECT", cur="CURRENT",
                    best="BEST", flags="FLAGS", death="DEATH/why"),
           "-" * 78]
    for r in rows:
        flags = ("U" if r["user_flag"] else "-") + ("R" if r["root_flag"] else "-")
        mark = "" if r["meets_expect"] else "  <- UNMET"
        reg = "  <- regressed-vs-best" if r["regressed_within_repo"] else ""
        out.append(w.format(box=r["box"], difficulty=str(r["difficulty"] or "?"),
                            expect=r["expect"], cur=r["current"], best=r["best"],
                            flags=flags, death=str(r["death"] or "")) + mark + reg)
    return "\n".join(out)


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
