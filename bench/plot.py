import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from analyze import feats
rec, kpdir, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
meta = json.loads((rec / "meta.json").read_text())
t = np.array(meta["stamps"]); t0 = t[0]; t = t - t0
names = ["rtmpose-t__crop", "movenet-lightning-f16__full", "blazepose-lite__track"]
keys = ["sw", "ed", "drop", "tilt", "lean_ang", "lean_off"]
fig, ax = plt.subplots(len(keys) + 1, 1, figsize=(16, 18), sharex=True)
cols = {"good": "#e8f5e9", "good_work": "#c8e6c9", "lean_in": "#ffcdd2", "head_drop": "#ffe0b2", "head_tilt": "#e1bee7", "side_lean": "#bbdefb", "side_look": "#fff9c4"}
for a in ax:
    for s in meta["segments"]:
        a.axvspan(s["start"] - t0, s["end"] - t0, color=cols[s["label"]], alpha=0.8)
for n in names:
    kp = np.load(kpdir / f"{n}.npy")[: len(t)]
    f = feats(kp)
    for a, k in zip(ax, keys):
        a.plot(t, f[k], label=n, lw=0.8); a.set_ylabel(k)
    ax[-1].plot(t, kp[:, :, 2].min(1), lw=0.8, label=n); ax[-1].set_ylabel("min score")
for s in meta["segments"]:
    ax[0].text(s["start"] - t0 + 1, ax[0].get_ylim()[1], s["label"], va="top", fontsize=8)
ax[0].legend(); plt.tight_layout(); plt.savefig(out, dpi=60)
