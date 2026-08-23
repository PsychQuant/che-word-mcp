#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE_SCRIPT="$ROOT/scripts/release.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/release-source-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

BINARY_NAME=$(sed -n 's/^BINARY_NAME="\([^"]*\)"/\1/p' "$SOURCE_SCRIPT" | head -1)
TEST_VERSION=$(grep -h 'static let serverVersion' "$ROOT"/Sources/*/Server.swift 2>/dev/null \
    | sed -n 's/.*"\([0-9][^"]*\)".*/\1/p' | head -1 || true)
[ -n "$TEST_VERSION" ] || TEST_VERSION=9.9.9

REPO="$TEST_ROOT/repo"
FAKE_PATH="$TEST_ROOT/fake-path"
EVENT_LOG="$TEST_ROOT/events.log"
mkdir -p "$REPO/scripts" "$FAKE_PATH"
cp "$SOURCE_SCRIPT" "$REPO/scripts/release.sh"
echo original > "$REPO/source.txt"
echo '.build/' > "$REPO/.gitignore"
SERVER_FILE=$(grep -l 'static let serverVersion' "$ROOT"/Sources/*/Server.swift 2>/dev/null | head -1 || true)
if [ -n "$SERVER_FILE" ]; then
    SERVER_RELATIVE=${SERVER_FILE#"$ROOT"/}
    mkdir -p "$REPO/$(dirname "$SERVER_RELATIVE")"
    cp "$SERVER_FILE" "$REPO/$SERVER_RELATIVE"
fi

git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .
git -C "$REPO" commit -qm baseline
BASELINE_HEAD=$(git -C "$REPO" rev-parse HEAD)
git init -q --bare "$TEST_ROOT/origin.git"
git -C "$REPO" remote add origin "$TEST_ROOT/origin.git"

cat > "$FAKE_PATH/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "ls-remote" ]; then exit 0; fi
exec /usr/bin/git "$@"
EOF

cat > "$FAKE_PATH/swift" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "test" ]; then exit 0; fi
echo swift-build >> "$EVENT_LOG"
case "${MUTATION_MODE:-none}" in
    file) echo changed-during-build >> source.txt ;;
    primary) echo changed-in-primary-tree >> "$PRIMARY_REPO/source.txt" ;;
    head)
        echo committed-during-build >> source.txt
        /usr/bin/git add source.txt
        /usr/bin/git commit -qm committed-during-build
        ;;
esac
mkdir -p .build/apple/Products/Release
cat > ".build/apple/Products/Release/$BINARY_NAME" <<'BIN'
#!/bin/bash
echo test-binary
BIN
chmod +x ".build/apple/Products/Release/$BINARY_NAME"
EOF

cat > "$FAKE_PATH/codesign" <<'EOF'
#!/bin/bash
echo codesign >> "$EVENT_LOG"
exit 0
EOF

cat > "$FAKE_PATH/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun:$*" >> "$EVENT_LOG"
if [ "${2:-}" = "submit" ]; then echo 'status: Accepted'; fi
exit 0
EOF

cat > "$FAKE_PATH/lipo" <<'EOF'
#!/bin/bash
echo 'arm64 x86_64'
EOF

cat > "$FAKE_PATH/ditto" <<'EOF'
#!/bin/bash
last=""
for last in "$@"; do :; done
: > "$last"
EOF

cat > "$FAKE_PATH/gh" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then exit 1; fi
if [ "${1:-}" = "release" ] && [ "${2:-}" = "create" ]; then
    echo "gh-release-create:$*" >> "$EVENT_LOG"
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_PATH"/*

run_release() {
    : > "$EVENT_LOG"
    set +e
    (
        cd "$REPO"
        EVENT_LOG="$EVENT_LOG" BINARY_NAME="$BINARY_NAME" MUTATION_MODE="$1" PRIMARY_REPO="$REPO" PATH="$FAKE_PATH:$PATH" \
            bash scripts/release.sh "$TEST_VERSION"
    ) >"$TEST_ROOT/output-$1.log" 2>&1
    RELEASE_RC=$?
    set -e
}

assert_no_release_side_effects() {
    if grep -q '^codesign$\|notarytool submit\|^gh-release-create:' "$EVENT_LOG"; then
        echo "FAIL: signing/notarization/upload ran after source drift" >&2
        cat "$EVENT_LOG" >&2
        exit 1
    fi
}

run_release file
[[ "$RELEASE_RC" -eq 3 ]] || {
    echo "FAIL: source mutation must stop release with exit 3; got $RELEASE_RC" >&2
    cat "$TEST_ROOT/output-file.log" >&2
    exit 1
}
assert_no_release_side_effects
grep -q 'tree changed during the build' "$TEST_ROOT/output-file.log"
/usr/bin/git -C "$REPO" checkout -q -- source.txt

run_release primary
[[ "$RELEASE_RC" -eq 0 ]] || {
    echo "FAIL: isolated release should ignore concurrent primary-tree edits; got $RELEASE_RC" >&2
    cat "$TEST_ROOT/output-primary.log" >&2
    exit 1
}
grep -q "^gh-release-create:.*--target $BASELINE_HEAD" "$EVENT_LOG"
/usr/bin/git -C "$REPO" checkout -q -- source.txt

run_release none
[[ "$RELEASE_RC" -eq 0 ]] || {
    echo "FAIL: clean release should complete in harness; got $RELEASE_RC" >&2
    cat "$TEST_ROOT/output-none.log" >&2
    exit 1
}
grep -q '^codesign$' "$EVENT_LOG"
grep -q "^gh-release-create:.*--target $BASELINE_HEAD" "$EVENT_LOG"

run_release head
[[ "$RELEASE_RC" -eq 3 ]] || {
    echo "FAIL: HEAD change must stop release with exit 3; got $RELEASE_RC" >&2
    cat "$TEST_ROOT/output-head.log" >&2
    exit 1
}
assert_no_release_side_effects
grep -q 'tree changed during the build' "$TEST_ROOT/output-head.log"

echo "PASS: release refuses source/HEAD drift before signing and pins target"
