#!/usr/bin/env bash
# Live resource run: each candidate captures N frames at 5 fps from the BRIO.
set -u
S=$1; N=$2
M=$(ls $S/dl/rtm/20230831/rtmpose_onnx/*/end2end.onnx)
MV=$S/dl/movenet/singlepose-lightning-tflite-float16/4.tflite
DEV=/dev/v4l/by-id/usb-046d_Logitech_BRIO_61129147-video-index0
PY="$S/venv/bin/python -I"
run() { $PY $S/bench/measure.py "$@"; sleep 2; }
run rust-tract-rtmpose -- $S/cargo-target-tract/release/posebench "$M" --dev $DEV --frames $N
run rust-ort-rtmpose -- $S/cargo-target-ort/release/posebench "$M" --dev $DEV --frames $N
run py-ort-rtmpose -- $S/venv/bin/python -I $S/bench/pyhelper.py "$M" --dev $DEV --frames $N
run py-litert-movenet -- $S/venv/bin/python -I $S/bench/pyhelper.py "$MV" --dev $DEV --frames $N
