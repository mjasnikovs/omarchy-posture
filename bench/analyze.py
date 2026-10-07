"""Score each model's keypoints on the labelled recording. Same rules for all.

Usage: python analyze.py REC_DIR KP_DIR
"""
import json
import sys
from pathlib import Path

import numpy as np

SLATE = (3.0, 8.0)
SKIP = 3.0  # seconds dropped at the start of each segment (transition)
BAD = ["lean_in", "head_drop", "head_tilt", "side_lean"]
OK = ["good", "good_work", "side_look"]
MIN_SCORE = 0.3
# Spread floors: below this the slate spread is treated as noise-free.
FLOOR = {"close": 0.02, "drop": 0.02, "tilt": 2.0, "lean_ang": 2.0, "lean_off": 0.02}


def labels(meta):
    t = np.array(meta["stamps"])
    lab = np.array([""] * len(t), dtype=object)
    for s in meta["segments"]:
        m = (t >= s["start"] + SKIP) & (t < s["end"])
        lab[m] = s["label"]
    g = meta["segments"][0]
    slate = np.where((t >= g["start"] + SLATE[0]) & (t < g["start"] + SLATE[1]))[0]
    lab[slate] = "slate"
    return lab, slate


def feats(kp):
    nose, le, re, lea, rea, ls, rs = (kp[:, i, :2] for i in range(7))
    sw = np.linalg.norm(ls - rs, axis=1)
    ed = np.linalg.norm(le - re, axis=1)
    sh_mid = (ls + rs) / 2
    head_mid = (le + re) / 2
    ang = lambda a, b: np.degrees(np.arctan2(a[:, 1] - b[:, 1], a[:, 0] - b[:, 0]))
    return {
        "sw": sw,
        "ed": ed,
        "drop": (sh_mid[:, 1] - nose[:, 1]) / sw,
        "tilt": ang(le, re),
        "lean_ang": ang(ls, rs),
        "lean_off": (head_mid[:, 0] - sh_mid[:, 0]) / sw,
    }


def check_scores(f, slate):
    m = {k: np.median(v[slate]) for k, v in f.items()}
    s = {k: np.std(v[slate]) for k, v in f.items()}
    close = 0.5 * (f["sw"] / m["sw"] + f["ed"] / m["ed"]) - 1
    close_sl = close[slate]
    z = lambda x, mean, sd, key: (x - mean) / max(sd, FLOOR[key])
    return {
        "lean_in": z(close, np.median(close_sl), np.std(close_sl), "close"),
        "head_drop": z(m["drop"] - f["drop"], 0, s["drop"], "drop"),
        "head_tilt": np.abs(z(f["tilt"], m["tilt"], s["tilt"], "tilt")),
        "side_lean": np.maximum(
            np.abs(z(f["lean_ang"], m["lean_ang"], s["lean_ang"], "lean_ang")),
            np.abs(z(f["lean_off"], m["lean_off"], s["lean_off"], "lean_off")),
        ),
    }


def auc(pos, neg):
    if len(pos) == 0 or len(neg) == 0:
        return float("nan")
    allv = np.concatenate([pos, neg])
    ranks = allv.argsort().argsort() + 1
    return (ranks[: len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


def main():
    rec, kpdir = Path(sys.argv[1]), Path(sys.argv[2])
    meta = json.loads((rec / "meta.json").read_text())
    timing = json.loads((kpdir / "timing.json").read_text())
    lab, slate = labels(meta)
    rows = []
    for p in sorted(kpdir.glob("*.npy")):
        kp = np.load(p)[: len(lab)]
        lab_ = lab[: len(kp)]
        valid = kp[:, :, 2].min(1) >= MIN_SCORE
        f = feats(kp)
        sc = check_scores(f, slate)
        total = np.max(np.stack(list(sc.values())), axis=0)
        total[~valid] = -np.inf  # unknown never alerts
        # jitter: still good segment after the slate window
        still = np.where(lab_ == "good")[0]
        still = still[still < np.where(lab_ == "lean_in")[0][0]]
        d = np.linalg.norm(np.diff(kp[still, :, :2], axis=0), axis=2)
        jitter = float(np.median(d) / np.median(f["sw"][slate]) * 100)
        neg = np.isin(lab_, OK)
        pos = np.isin(lab_, BAD)
        aucs = {}
        for c in BAD:
            pm = (lab_ == c) & valid
            nm = np.isin(lab_, ["good", "good_work"]) & valid
            aucs[c] = auc(sc[c][pm], sc[c][nm])
        best = (0, 0)
        for k in np.linspace(1, 30, 291):
            pred = total > k
            ba = 0.5 * (pred[pos].mean() + (~pred[neg]).mean())
            if ba > best[0]:
                best = (ba, k)
        k = best[1]
        pred = total > k
        per = {c: round(float(pred[lab_ == c].mean()) * 100) for c in BAD + OK}
        rows.append({
            "model": p.stem,
            "ms": round(timing.get(p.stem, float("nan")), 1),
            "valid%": round(float(valid.mean()) * 100, 1),
            "jitter%sw": round(jitter, 2),
            "auc": {c: round(v, 3) for c, v in aucs.items()},
            "bal_acc": round(best[0] * 100, 1),
            "k": round(k, 1),
            "flag%": per,
        })
    for r in sorted(rows, key=lambda r: -r["bal_acc"]):
        print(json.dumps(r))


if __name__ == "__main__":
    main()
