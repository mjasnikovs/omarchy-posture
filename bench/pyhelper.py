"""Python candidate helper: linuxpy capture -> RTMPose-t (onnxruntime) -> JSON lines.
Usage: python pyhelper.py MODEL (--dev PATH --frames N | --replay FILE) [--crop cx,cy,w,h]
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import numpy as np
from models import MoveNet, RTMPose, yuyv_to_rgb

W, H = 640, 480


def main():
    a = sys.argv
    get = lambda k: a[a.index(k) + 1] if k in a else None
    crop = tuple(float(x) for x in get("--crop").split(",")) if get("--crop") else None

    def sess(p):
        import onnxruntime as ort
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1
        o.inter_op_num_threads = 1
        return ort.InferenceSession(p, o, providers=["CPUExecutionProvider"])

    if a[1].endswith(".tflite"):
        from ai_edge_litert.interpreter import Interpreter
        m = MoveNet(a[1], lambda p: Interpreter(model_path=p, num_threads=1), "movenet")
    else:
        m = RTMPose(a[1], sess)
    out = sys.stdout

    def step(buf):
        t0 = time.perf_counter()
        kp = m.infer(yuyv_to_rgb(buf, W, H), crop)
        out.write('{"ms":%.2f,"kp":[%s]}\n' % ((time.perf_counter() - t0) * 1e3,
                  ",".join("[%.2f,%.2f,%.3f]" % tuple(p) for p in kp)))

    if get("--replay"):
        with open(get("--replay"), "rb") as f:
            while len(buf := f.read(W * H * 2)) == W * H * 2:
                step(buf)
        return
    from linuxpy.video.device import Device, PixelFormat
    with Device(get("--dev")) as cam:
        cam.set_format(1, W, H, PixelFormat.YUYV)
        cam.set_fps(1, 5)
        n = int(get("--frames"))
        for i, frame in enumerate(cam):
            step(bytes(frame))
            if i + 1 >= n:
                break


if __name__ == "__main__":
    main()
