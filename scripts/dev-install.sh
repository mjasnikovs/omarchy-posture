#!/usr/bin/env bash
# Dev loop: build, then copy the plugin into the shell's plugin folder and
# the helper into ~/.local/bin. Develop outside ~/.config/omarchy/plugins:
# the shell refuses symlinks, and node_modules has some.
set -euo pipefail
cd "$(dirname "$0")/.."

bun run build
(cd helper && cargo build --release)

dest="$HOME/.config/omarchy/plugins/mjasnikovs.posture"
mkdir -p "$dest"
cp manifest.json Model.mjs ./*.qml LICENSE "$dest/"
install -Dm755 helper/target/release/omarchy-posture-helper "$HOME/.local/bin/omarchy-posture-helper"

model="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-posture/rtmpose-t.onnx"
[[ -f $model ]] || scripts/fetch-model.sh "$model"
echo "installed: $dest"
