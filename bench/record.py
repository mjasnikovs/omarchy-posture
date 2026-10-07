"""Guided recording for the bake-off. Frames stay in the scratchpad.

Usage: python record.py OUT_DIR
Writes OUT_DIR/frames.yuyv (640x480 YUYV), OUT_DIR/meta.json (timestamps, segments).
Prompts arrive as desktop notifications.
"""
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

W, H, FPS = 640, 480, 5
DEV = "/dev/v4l/by-id/usb-046d_Logitech_BRIO_61129147-video-index0"
SEGMENTS = [
    ("good", 30, "Sit in your GOOD posture. Look at the main screen. Stay natural."),
    ("lean_in", 20, "LEAN IN toward the screen, like reading small text."),
    ("good", 15, "Back to GOOD posture."),
    ("head_drop", 20, "SLOUCH: round your back, let your head sink."),
    ("good", 15, "Back to GOOD posture."),
    ("head_tilt", 20, "TILT your head to one side. Switch side halfway."),
    ("good", 15, "Back to GOOD posture."),
    ("side_lean", 20, "LEAN your body to one side, shoulders uneven. Switch halfway."),
    ("good", 15, "Back to GOOD posture."),
    ("side_look", 20, "Sit well, but LOOK AT A SIDE MONITOR. Switch side halfway."),
    ("good_work", 30, "Sit well and WORK normally: type, use the mouse, glance at keyboard."),
]


def show(text, left=None):
    sys.stdout.write("\033[2J\033[H\n")
    sys.stdout.write(text.replace(". ", ".\n") + "\n\n")
    if left is not None:
        sys.stdout.write(f"   {left} s\n")
    sys.stdout.flush()


def countdown(text, secs):
    end = time.time() + secs
    while (left := end - time.time()) > 0:
        show(text, int(left) + 1)
        time.sleep(min(1, left))


notify = show


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    stamps = []
    stop = threading.Event()

    def reader():
        size = W * H * 2
        with open(out / "frames.yuyv", "wb") as f:
            while not stop.is_set():
                buf = ff.stdout.read(size)
                if len(buf) < size:
                    break
                stamps.append(time.time())
                f.write(buf)

    t = threading.Thread(target=reader)
    show("Preview opens. Tilt the camera so your upper chest shows. Press q in the preview to close it.")
    subprocess.run(["ffplay", "-loglevel", "error", "-f", "v4l2", "-input_format", "yuyv422",
                    "-video_size", f"{W}x{H}", "-window_title", "posture-preview", DEV], check=False)
    input("Press Enter to start recording.")
    countdown("Get ready. Camera on.", 5)
    ff = subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-f", "v4l2", "-input_format", "yuyv422",
         "-framerate", str(FPS), "-video_size", f"{W}x{H}", "-i", DEV,
         "-c:v", "rawvideo", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE,
    )
    t.start()
    segs = []
    for label, secs, text in SEGMENTS:
        start = time.time()
        countdown(text, secs)
        segs.append({"label": label, "start": start, "end": time.time()})
    stop.set()
    ff.terminate()
    t.join()
    show("Done. Thank you. You can close this window.")
    (out / "meta.json").write_text(json.dumps({"w": W, "h": H, "fps": FPS, "stamps": stamps, "segments": segs}))
    print(f"frames: {len(stamps)}")


if __name__ == "__main__":
    main()
