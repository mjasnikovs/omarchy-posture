"""Run every model over a recording. Saves keypoints per model+crop mode.

Usage: python run.py DL_DIR REC_DIR OUT_DIR
"""
import glob
import json
import sys
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
from ai_edge_litert.interpreter import Interpreter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from models import BlazePose, MoveNet, RTMPose, yuyv_to_rgb

SLATE = (3.0, 8.0)  # seconds into the first good segment


def ort_session(path):
    o = ort.SessionOptions()
    o.intra_op_num_threads = 1
    o.inter_op_num_threads = 1
    return ort.InferenceSession(path, o, providers=["CPUExecutionProvider"])


def tfl(path):
    return Interpreter(model_path=path, num_threads=1)


def frames(rec):
    meta = json.loads((rec / "meta.json").read_text())
    w, h = meta["w"], meta["h"]
    raw = np.fromfile(rec / "frames.yuyv", np.uint8)
    n = min(len(meta["stamps"]), raw.size // (w * h * 2))
    return meta, raw[: n * w * h * 2].reshape(n, h, w, 2)


def slate_idx(meta):
    g = meta["segments"][0]
    t = np.array(meta["stamps"])
    return np.where((t >= g["start"] + SLATE[0]) & (t < g["start"] + SLATE[1]))[0]


def crop_from(kp, idx):
    m = np.median(kp[idx], axis=0)
    sx, sy = (m[5, :2] + m[6, :2]) / 2
    sw = abs(m[5, 0] - m[6, 0])
    return (float(sx), float(sy - 0.25 * sw), 2.4 * sw, 2.4 * sw)


def run(model, fr, crop):
    out = np.zeros((len(fr), 7, 3), np.float32)
    times = []
    for i, f in enumerate(fr):
        rgb = yuyv_to_rgb(f.tobytes(), f.shape[1], f.shape[0])
        t0 = time.perf_counter()
        out[i] = model.infer(rgb, crop)
        times.append(time.perf_counter() - t0)
    return out, float(np.median(times) * 1000)


def main():
    dl, rec, outdir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    outdir.mkdir(parents=True, exist_ok=True)
    meta, fr = frames(rec)
    sidx = slate_idx(meta)
    rtm = glob.glob(str(dl / "rtm/**/end2end.onnx"), recursive=True)[0]
    models = [
        RTMPose(rtm, ort_session),
        MoveNet(str(dl / "movenet/singlepose-lightning-tflite-int8/4.tflite"), tfl, "movenet-lightning-int8"),
        MoveNet(str(dl / "movenet/singlepose-lightning-tflite-float16/4.tflite"), tfl, "movenet-lightning-f16"),
        MoveNet(str(dl / "movenet/singlepose-thunder-tflite-int8/4.tflite"), tfl, "movenet-thunder-int8"),
    ]
    timing = {}
    if (outdir / "timing.json").exists():
        timing = json.loads((outdir / "timing.json").read_text())
    for m in models:
        if f"{m.name}__crop" in timing:
            continue
        kp, ms = run(m, fr, None)
        np.save(outdir / f"{m.name}__full.npy", kp)
        timing[f"{m.name}__full"] = ms
        kp2, ms2 = run(m, fr, crop_from(kp, sidx))
        np.save(outdir / f"{m.name}__crop.npy", kp2)
        timing[f"{m.name}__crop"] = ms2
        print(m.name, round(ms, 1), round(ms2, 1), flush=True)
        (outdir / "timing.json").write_text(json.dumps(timing, indent=1))
    b = BlazePose(str(dl / "blaze/pose_detector.tflite"), str(dl / "blaze/pose_landmarks_detector.tflite"), tfl)
    kp, ms = run(b, fr, None)
    np.save(outdir / "blazepose-lite__track.npy", kp)
    timing["blazepose-lite__track"] = ms
    print(b.name, round(ms, 1), flush=True)
    (outdir / "timing.json").write_text(json.dumps(timing, indent=1))


if __name__ == "__main__":
    main()
