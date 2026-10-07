# Bake-off results (2026-10-07)

One person, one 3.6-minute recording, Logitech BRIO top-center, 640x480 YUYV at 5 fps.
Segments: good, lean in, head drop, head tilt, side lean, look at side monitor, normal work.
The first 3 s of each segment are dropped as transition. The slate is seconds 3–8 of the first good segment.
Raw frames were deleted after scoring. Only keypoints are kept in `fixtures/`.

## Quality (same scoring rules for every model, `analyze.py`)

| Model | Balanced acc. | Jitter (% shoulder width) | Valid frames |
|---|---|---|---|
| MoveNet Lightning f16, full frame | 91.6 | 1.83 | 99.5% |
| RTMPose-t, full frame | 91.5 | 1.73 | 100% |
| MoveNet Lightning f16, crop | 91.2 | 1.92 | 94.9% |
| BlazePose lite (tracked ROI) | 91.1 | 2.46 | 100% |
| RTMPose-t, crop | 90.4 | 1.98 | 100% |
| MoveNet Thunder int8, crop | 83.0 | 2.15 | 88.8% |
| MoveNet Lightning int8, crop | 74.0 | 3.10 | 84.6% |

Rule: within 2 points of the best accuracy, and jitter no more than 10% worse than the best.
Pass: RTMPose-t full frame, MoveNet Lightning f16 full frame.

## Runtime equivalence (RTMPose-t, 200 replayed frames)

| Pair | Mean diff | Max diff |
|---|---|---|
| Rust ort vs Rust tract | 0.001 px | 1.67 px (1 frame) |
| Python ort vs Rust | 0.14 px | 2.36 px |

The model's output step is 1.67 px. All runtimes give the same quality.
tract cannot load MoveNet .tflite (unsupported CAST op). MoveNet runs only on LiteRT.

## Resources (live camera, 300 frames at 5 fps, 1 inference thread)

| Candidate | Disk (MB) | Peak RAM (MB) | CPU (% of one core) | Frame time (ms) |
|---|---|---|---|---|
| Rust + tract + RTMPose-t | 33 | 35 | 7.7 | 15.9 |
| Rust + ort (static) + RTMPose-t | 36 | 52 | 4.8 | 9.7 |
| Python + LiteRT + MoveNet f16 | ~131 | 80 | 11.8 | 19.9 |
| Python + onnxruntime + RTMPose-t | ~142 | 101 | 12.7 | 21.2 |

Disk includes the 13.4 MB RTMPose-t or 4.8 MB MoveNet model. Python sizes exclude the interpreter.
