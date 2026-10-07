#!/usr/bin/env bash
# Final gate before a push that users will install from. Checks what is
# committed, not the working copy.
#
# 1. Model.mjs must be tracked and match HEAD, and src/, the QML and the
#    helper source must be committed.
#    The marketplace installs the raw repo with no build step.
# 2. The committed tree, extracted without node_modules, must pass the
#    shell's plugin validator (it refuses symlinks, which node_modules has).
# 3. One version everywhere, and the AUR package must pin its tarball.
set -euo pipefail
cd "$(dirname "$0")/.."

git ls-files --error-unmatch Model.mjs >/dev/null 2>&1 || {
    echo "release: Model.mjs is not tracked. Run: bun run build && git add Model.mjs" >&2
    exit 1
}
# git diff ignores new files, and git archive would leave them out.
untracked=$(git ls-files --others --exclude-standard -- src ./*.qml manifest.json LICENSE THIRD_PARTY.md \
    helper/src helper/Cargo.toml helper/Cargo.lock)
if [[ -n $untracked ]]; then
    echo "release: files not committed:" >&2
    echo "$untracked" >&2
    exit 1
fi
if ! git diff --quiet HEAD -- Model.mjs src/ ./*.qml manifest.json LICENSE THIRD_PARTY.md \
    helper/src helper/Cargo.toml helper/Cargo.lock; then
    echo "release: plugin or helper files differ from HEAD. Commit first." >&2
    git --no-pager diff --stat HEAD -- Model.mjs src/ ./*.qml manifest.json helper/ >&2
    exit 1
fi

version=$(jq -r .version manifest.json)
for got in "$(jq -r .version package.json)" \
    "$(sed -n 's/^version = "\(.*\)"/\1/p' helper/Cargo.toml | head -1)" \
    "$(sed -n 's/^pkgver=//p' packaging/aur/PKGBUILD)" \
    "$(sed -n 's/^\tpkgver = //p' packaging/aur/.SRCINFO)"; do
    [[ $got == "$version" ]] || {
        echo "release: version mismatch: manifest.json says $version, found $got" >&2
        echo "  check package.json, helper/Cargo.toml, packaging/aur/PKGBUILD and .SRCINFO" >&2
        exit 1
    }
done
if grep -q "^sha256sums=('SKIP'" packaging/aur/PKGBUILD || grep -q "sha256sums = SKIP" packaging/aur/.SRCINFO; then
    echo "release: PKGBUILD tarball sum is SKIP. Tag v$version, then run updpkgsums and makepkg --printsrcinfo." >&2
    exit 1
fi

stage=".release"
rm -rf "$stage"
mkdir -p "$stage"
git archive HEAD | tar -x -C "$stage"
omarchy plugin validate "$stage"
rm -rf "$stage"
echo "release: ok"
