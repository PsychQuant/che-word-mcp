#!/bin/bash
# release.sh — signed + notarized release pipeline for CheWordMCP (PsychQuant/che-word-mcp).
#
# Usage: scripts/release.sh <version>        # e.g. scripts/release.sh 0.2.0
#
# Pipeline: universal build → Developer ID codesign (hardened runtime +
# timestamp) → PRE-UPLOAD SIGNATURE GATE → notarize (must be Accepted) →
# universal check → sha256 → git tag → gh release with binary + .sha256.
#
# The gate exists because v3.20.0 of CheWordMCP shipped ad-hoc signed
# (che-word-mcp#165): the marketplace wrappers verify the SAME requirement
# on install/exec (PsychQuant/macdoc#112), so an unsigned asset means new
# installs hard-fail. Gate requirement string MUST stay in lockstep with
# the wrapper's verify_binary() (macdoc plugins/*/bin/*-wrapper.sh).
#
# SCOPE HONESTY (verify DA-1): this gate protects releases made THROUGH
# this script. A manual `gh release upload` bypasses it — the backstops
# for that path are process discipline and the wrappers' fail-closed
# install gate (which turns an unsigned asset into a loud install failure
# rather than a silent compromise).
#
# Refs PsychQuant/macdoc#119.

set -euo pipefail

BINARY_NAME="CheWordMCP"
REPO="PsychQuant/che-word-mcp"
DEVELOPER_ID="${DEVELOPER_ID:-F2523DCF6D02BE99B67C7D27F633119292DA4934}"
NOTARY_PROFILE="${NOTARY_PROFILE:-che-mcps-notary}"
REQUIREMENT='=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "6W377FS7BS"'

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: scripts/release.sh <version>  (e.g. 0.2.0, no leading v)" >&2; exit 2; }
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || { echo "error: version '$VERSION' is not semver (MAJOR.MINOR.PATCH[-prerelease], no leading zeros)" >&2; exit 2; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "→ [0/7] pre-flight: notary profile alive?"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "error: notary profile '$NOTARY_PROFILE' unusable — run: xcrun notarytool store-credentials $NOTARY_PROFILE (interactive, user-only)" >&2; exit 3; }
SOURCE_HEAD=$(git rev-parse HEAD) || { echo "error: cannot resolve source HEAD" >&2; exit 3; }
SOURCE_STATUS=$(git status --porcelain) || { echo "error: cannot inspect working tree status" >&2; exit 3; }
[[ -z "$SOURCE_STATUS" ]] \
    || { echo "error: working tree not clean (including untracked files — they could leak into the build) — commit, stash, or clean first" >&2; exit 3; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
    echo "error: local tag v$VERSION already exists" >&2; exit 3
fi
if [[ -n "$(git ls-remote --tags origin "refs/tags/v$VERSION" 2>/dev/null)" ]]; then
    echo "error: remote tag v$VERSION already exists" >&2; exit 3
fi
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: release v$VERSION already exists on $REPO" >&2; exit 3
fi

BUILD_PARENT=$(mktemp -d) || { echo "error: cannot create isolated build directory" >&2; exit 3; }
BUILD_TREE="$BUILD_PARENT/source"
WORKDIR=""
cleanup() {
    if [ -d "$BUILD_TREE" ]; then git worktree remove --force "$BUILD_TREE" >/dev/null 2>&1 || true; fi
    rm -rf "$BUILD_PARENT"
    if [ -n "$WORKDIR" ]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT
git worktree add --detach "$BUILD_TREE" "$SOURCE_HEAD" >/dev/null \
    || { echo "error: cannot materialize isolated build tree for $SOURCE_HEAD" >&2; exit 3; }

# Script-pipeline parity gate (PsychQuant/macdoc#167). The ungated
# ScriptPipelineParityTests always run here; the CLI cross-check + JPA
# coverage parity tests additionally run when their env gates are present.
# The maintainer's release machine has both MACDOC_TEMPLATE_DIR and a macdoc
# binary, so on the release path this hard-requires MCP↔CLI parity; a machine
# without the private template still runs the ungated tests and only warns
# about the skipped cross-check (loud, never silent — the whole point of #167).
echo "→ [0.5/7] pre-flight: script-pipeline parity tests"
if [[ -z "${MACDOC_TEMPLATE_DIR:-}" || -z "${MACDOC_CLI_PATH:-}" ]]; then
    echo "  ⚠ gated cross-check will SKIP — set MACDOC_TEMPLATE_DIR + MACDOC_CLI_PATH to run the full MCP↔CLI byte-equal parity check (ungated parity tests still run below)." >&2
fi
swift test --package-path "$BUILD_TREE" --filter ScriptPipelineParityTests \
    || { echo "error: script-pipeline parity tests failed — refusing to release a binary whose MCP tools drifted from the CLI" >&2; exit 3; }

echo "→ [1/7] universal release build from isolated commit $SOURCE_HEAD"
(cd "$BUILD_TREE" && swift build -c release --arch arm64 --arch x86_64)
BIN="$BUILD_TREE/.build/apple/Products/Release/$BINARY_NAME"
[[ -f "$BIN" ]] || { echo "error: built binary not found at $BIN" >&2; exit 4; }

BUILD_HEAD_AFTER=$(git -C "$BUILD_TREE" rev-parse HEAD) || { echo "error: cannot re-read isolated build HEAD" >&2; exit 3; }
BUILD_STATUS_AFTER=$(git -C "$BUILD_TREE" status --porcelain) || { echo "error: cannot inspect isolated build tree status" >&2; exit 3; }
[[ "$BUILD_HEAD_AFTER" == "$SOURCE_HEAD" && -z "$BUILD_STATUS_AFTER" ]] \
    || { echo "error: isolated build tree changed during the build — refusing to sign bytes that may not correspond to commit $SOURCE_HEAD" >&2; exit 3; }

echo "→ [2/7] codesign (Developer ID, hardened runtime, timestamp)"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$BIN"

echo "→ [3/7] PRE-UPLOAD SIGNATURE GATE (requirement-based, matches wrapper)"
codesign --verify --strict -R "$REQUIREMENT" "$BIN" \
    || { echo "error: GATE FAILED — asset is not a Developer ID Application binary of Team 6W377FS7BS; refusing to release (this is the che-word-mcp#165 guard)" >&2; exit 5; }
ARCHS=" $(lipo -archs "$BIN" 2>/dev/null) "
[[ "$ARCHS" == *" arm64 "* && "$ARCHS" == *" x86_64 "* ]] \
    || { echo "error: GATE FAILED — binary is not universal (need arm64 + x86_64, got:$ARCHS)" >&2; exit 5; }

echo "→ [4/7] notarize (must be Accepted)"
WORKDIR=$(mktemp -d)
ditto -c -k --keepParent "$BIN" "$WORKDIR/$BINARY_NAME.zip"
NOTARY_OUT=$(xcrun notarytool submit "$WORKDIR/$BINARY_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
echo "$NOTARY_OUT" | grep -q "status: Accepted" \
    || { echo "error: notarization not Accepted:" >&2; echo "$NOTARY_OUT" | tail -5 >&2; exit 6; }

echo "→ [5/7] sha256 asset"
cp "$BIN" "$WORKDIR/$BINARY_NAME"
shasum -a 256 "$WORKDIR/$BINARY_NAME" | awk '{print $1}' > "$WORKDIR/$BINARY_NAME.sha256"

echo "→ [6/7] FINAL GATE — re-verify the exact upload artifact (TOCTOU guard)"
codesign --verify --strict -R "$REQUIREMENT" "$WORKDIR/$BINARY_NAME" \
    || { echo "error: FINAL GATE FAILED — upload artifact no longer passes the signature requirement (mutated after step 3?)" >&2; exit 5; }
[[ "$(shasum -a 256 "$WORKDIR/$BINARY_NAME" | awk '{print $1}')" == "$(cat "$WORKDIR/$BINARY_NAME.sha256")" ]] \
    || { echo "error: FINAL GATE FAILED — sha256 asset does not match upload artifact" >&2; exit 5; }

echo "→ [7/7] gh release create (creates tag v$VERSION at source commit $SOURCE_HEAD)"
gh release create "v$VERSION" --repo "$REPO" \
    --target "$SOURCE_HEAD" \
    --title "v$VERSION" \
    --notes "Developer ID signed + Apple notarized universal binary (arm64 + x86_64) built from commit $SOURCE_HEAD. Released via scripts/release.sh (source-stability + pre-upload signature gates, PsychQuant/macdoc#119)." \
    "$WORKDIR/$BINARY_NAME" "$WORKDIR/$BINARY_NAME.sha256"

echo "✓ released $BINARY_NAME v$VERSION (signed, notarized, gated, sha256 attached)"
