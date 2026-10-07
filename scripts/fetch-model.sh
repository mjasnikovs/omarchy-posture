#!/usr/bin/env bash
# Download RTMPose-t (Apache-2.0, OpenMMLab) and install the ONNX file at $1.
# Both the archive and the model are checked against pinned sha256 sums.
set -euo pipefail

dest=${1:?usage: fetch-model.sh DEST.onnx}
url=https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/rtmpose-t_simcc-body7_pt-body7_420e-256x192-026a1439_20230504.zip
zip_sha=937003a70832d9cc34ea16927f504792f3133e92dda1b9c626236bbbe9e805cb
onnx_sha=a6c2f6a3896a4d51131d14d7a80a3d08b50f559af5a58a45d5b098aef510a70f

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/model.zip" "$url"
echo "$zip_sha  $tmp/model.zip" | sha256sum -c --quiet
unzip -q -j "$tmp/model.zip" '*/end2end.onnx' -d "$tmp"
echo "$onnx_sha  $tmp/end2end.onnx" | sha256sum -c --quiet
install -Dm644 "$tmp/end2end.onnx" "$dest"
echo "model: $dest"
