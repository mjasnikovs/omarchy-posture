# Third-party components

## RTMPose-t model (`rtmpose-t.onnx`)

- Source: OpenMMLab MMPose, RTMPose project
  <https://github.com/open-mmlab/mmpose/tree/main/projects/rtmpose>
- File: `rtmpose-t_simcc-body7_pt-body7_420e-256x192-026a1439_20230504.zip`, `end2end.onnx`
- sha256 (onnx): `a6c2f6a3896a4d51131d14d7a80a3d08b50f559af5a58a45d5b098aef510a70f`
- License: Apache-2.0 (MMPose)
- The weights were trained on the "body7" dataset mix described in the RTMPose
  README. Those datasets carry their own terms.

The model is not stored in this repository. `scripts/fetch-model.sh` and the
AUR package download it and check its checksum.

## Rust crates

The helper links `tract-onnx` (MIT or Apache-2.0) and `v4l` (MIT). Run
`cargo tree` in `helper/` for the full list.
