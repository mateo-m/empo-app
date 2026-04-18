#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/Empo"
PROJECT_YML="$PROJECT_DIR/project.yml"
IPA_DIR="$REPO_ROOT/build/ipa"

usage() {
    echo "usage: $0 <version>"
    echo "  version  semver without 'v' prefix (e.g. 0.1.0)"
    exit 1
}

[[ $# -ne 1 ]] && usage
VERSION="$1"

# Validate semver format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be semver (e.g. 0.1.0), got: $VERSION"
    exit 1
fi

echo "==> releasing v$VERSION"

# 1. Check clean tree
if ! git -C "$REPO_ROOT" diff --quiet HEAD; then
    echo "error: working tree is dirty - commit or stash changes first"
    exit 1
fi

# 2. Bump MARKETING_VERSION in project.yml
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $VERSION/" "$PROJECT_YML"

# 3. Inject CURRENT_PROJECT_VERSION from commit count
BUILD=$(git -C "$REPO_ROOT" rev-list --count HEAD)
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD/" "$PROJECT_YML"

echo "    version: $VERSION, build: $BUILD"

# 4. Regenerate Xcode project
cd "$PROJECT_DIR"
/opt/homebrew/bin/xcodegen generate --spec project.yml --project . --quiet

# 5. Commit and tag (signed)
git -C "$REPO_ROOT" add "$PROJECT_YML" ios/Empo/Empo.xcodeproj/project.pbxproj
git -C "$REPO_ROOT" commit -S -m "chore: bump version to $VERSION (build $BUILD)"
git -C "$REPO_ROOT" tag -s "v$VERSION" -m "v$VERSION"

# 6. Build unsigned .ipa
echo "==> building unsigned ipa"
BUILD_DIR="$PROJECT_DIR/build/Release-iphoneos"
xcodebuild \
    -project "$PROJECT_DIR/Empo.xcodeproj" \
    -target Empo \
    -sdk iphoneos \
    -arch arm64 \
    -configuration Release \
    CODE_SIGNING_ALLOWED=NO \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    build 2>&1 | grep -E "^(Build|error:|warning: |CompileSwift|Ld )" || true

APP_PATH="$BUILD_DIR/Empo.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build failed - Empo.app not found at $BUILD_DIR"
    exit 1
fi

mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/Empo.app"
IPA_NAME="Empo-${VERSION}-unsigned.ipa"
(cd "$IPA_DIR" && zip -qr "$IPA_NAME" Payload)
rm -rf "$IPA_DIR/Payload"
IPA_PATH="$IPA_DIR/$IPA_NAME"
echo "    ipa: $IPA_PATH"

# 7. Generate changelog
CHANGELOG=""
if command -v git-cliff &>/dev/null; then
    CHANGELOG=$(git-cliff --config "$REPO_ROOT/cliff.toml" --unreleased --strip all 2>/dev/null || true)
fi

if [[ -z "$CHANGELOG" ]]; then
    CHANGELOG="See commit history for changes."
fi

# 8. Push
echo "==> pushing to origin"
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "v$VERSION"

# 9. Create GitHub release
echo "==> creating github release"
gh release create "v$VERSION" \
    --title "v$VERSION" \
    --notes "## What's changed

$CHANGELOG

---
> Unsigned build - resign with [SideStore](https://sidestore.io), AltStore, or Sideloadly before installing." \
    "$IPA_PATH"

echo "==> done - v$VERSION released"
