#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/Empo"
PROJECT_YML="$PROJECT_DIR/project.yml"
IPA_DIR="$REPO_ROOT/build/ipa"
ALTSTORE_SOURCE="$REPO_ROOT/altstore-source.json"
CHANGELOG_PATH="$REPO_ROOT/CHANGELOG.md"

usage() {
    echo "usage: $0 <bump>"
    echo "  bump   major | minor | patch     bump latest tag's segment"
    echo "         <semver>                  explicit version (e.g. 0.1.0)"
    echo ""
    echo "Every release run:"
    echo "  1. verifies empo-deps pins and hydrates native prebuilts"
    echo "     (set RELEASE_REBUILD_DEPS=1 to rebuild from source)"
    echo "  2. bumps version, tags, builds Empo.app + IPA"
    echo "  3. audits the shipped binary before publishing"
    exit 1
}

[[ $# -ne 1 ]] && usage
BUMP_OR_VERSION="$1"

# Resolve the new version. Accepts an explicit semver (`0.1.0`) for
# rare jumps that don't follow the bump-the-last-tag pattern, or one
# of `major` / `minor` / `patch` to derive it from the latest git
# tag matching `v*.*.*`. Falls back to `0.1.0` when no prior tag
# exists so the first release-cut works without a manual seed.
case "$BUMP_OR_VERSION" in
    major | minor | patch)
        LATEST_TAG=$(git -C "$REPO_ROOT" tag --list "v*.*.*" --sort=-v:refname | head -n 1)
        if [[ -z "$LATEST_TAG" ]]; then
            echo "    no prior v*.*.* tag found; seeding at 0.1.0"
            VERSION="0.1.0"
        else
            CURRENT="${LATEST_TAG#v}"
            IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT"
            case "$BUMP_OR_VERSION" in
                major) VERSION="$((MAJOR + 1)).0.0" ;;
                minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
                patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
            esac
            echo "    bumping $BUMP_OR_VERSION: $LATEST_TAG -> v$VERSION"
        fi
        ;;
    *)
        if ! [[ "$BUMP_OR_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "error: argument must be major|minor|patch or a semver"
            echo "       (e.g. 0.1.0), got: $BUMP_OR_VERSION"
            exit 1
        fi
        VERSION="$BUMP_OR_VERSION"
        ;;
esac

echo "==> releasing v$VERSION"

if ! command -v git-cliff >/dev/null 2>&1; then
    echo "error: git-cliff is required to generate release notes"
    exit 1
fi

# Refuse to bump onto an existing tag. Re-cutting an already-shipped
# version overwrites the tag + GitHub release in place, which is
# almost never what `release.sh` should be doing automatically. Use
# manual `git tag -fs` + `gh release upload --clobber` for that
# flow.
if git -C "$REPO_ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "error: tag v$VERSION already exists; pick a different bump"
    exit 1
fi

# 1. Check clean tree
if ! git -C "$REPO_ROOT" diff --quiet HEAD; then
    echo "error: working tree is dirty - commit or stash changes first"
    exit 1
fi

# 2. Verify dependency pins resolve to published empo-deps releases,
# then hydrate prebuilts for the device build. Override with
# RELEASE_REBUILD_DEPS=1 to rebuild from source (dep-bump maintainer flow).
echo "==> verifying empo-deps pins"
if [ "${RELEASE_REBUILD_DEPS:-0}" = "1" ]; then
    REQUIRE_PUBLISHED=0 "$REPO_ROOT/scripts/verify-empo-deps-pins.sh"
else
    REQUIRE_PUBLISHED=1 "$REPO_ROOT/scripts/verify-empo-deps-pins.sh"
fi

if [ "${RELEASE_REBUILD_DEPS:-0}" = "1" ]; then
    echo "==> rebuilding device native deps from source (RELEASE_REBUILD_DEPS=1)"
    "$REPO_ROOT/scripts/rebuild-device-deps.sh"
else
    echo "==> hydrating native deps from empo-deps"
    rm -rf "$REPO_ROOT/ios/Dependencies/build-iphoneos-arm64" \
        "$REPO_ROOT/ios/Dependencies/native/.fetched-version"
    sh "$REPO_ROOT/tools/fetch-native-deps.sh"
fi
"$REPO_ROOT/scripts/verify-device-deps.sh"

# 3. Bump MARKETING_VERSION in project.yml
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $VERSION/" "$PROJECT_YML"

# 4. Inject CURRENT_PROJECT_VERSION from commit count
BUILD=$(git -C "$REPO_ROOT" rev-list --count HEAD)
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD/" "$PROJECT_YML"

echo "    version: $VERSION, build: $BUILD"

# 5. Regenerate Xcode project
cd "$PROJECT_DIR"
/opt/homebrew/bin/xcodegen generate --spec project.yml --project . --quiet
cd "$REPO_ROOT"

# 6. Ad-hoc sign with our entitlements file so the Mach-O has an
# entitlements blob embedded. Sideloaders that resign the IPA
# (AltStore, Sideloadly, ESign, Feather) read this blob as their
# template; without it some resigners synthesize an incomplete
# blob and break runtime behaviors. iOS won't trust the ad-hoc
# signature directly, but every sideloader re-signs over it with
# the user's cert before installing.
#
# `--generate-entitlement-der` writes the modern DER-encoded
# entitlements format alongside the plist form. Required by
# iOS 15+ for some entitlement keys to be honored, and makes
# the signature easier for naive resigners to round-trip
# without losing data.
#
# Don't pass `--options=runtime`: hardened runtime is a macOS
# concept (restricts JIT/dyld/debugger), and setting it on an
# iOS binary makes dyld refuse to load the Mach-O at app
# launch, producing a black screen on startup.
# 7. Generate release notes before the version-bump commit so
# `--unreleased --tag` covers everything since the previous tag
# under the version we're about to ship. After prepending the entry to
# CHANGELOG.md, re-read that section back out so every downstream
# consumer (AltStore + GitHub release) uses the exact committed text.
echo "==> generating release notes"
FULL_CHANGELOG_ENTRY=$(git-cliff --config "$REPO_ROOT/cliff.toml" --unreleased --tag "v$VERSION")

if [[ -f "$CHANGELOG_PATH" ]]; then
    git-cliff --config "$REPO_ROOT/cliff.toml" --unreleased --tag "v$VERSION" --prepend "$CHANGELOG_PATH"
else
    printf '%s\n' "$FULL_CHANGELOG_ENTRY" >"$CHANGELOG_PATH"
fi

perl -0pi -e 's/\n{3,}/\n\n/g' "$CHANGELOG_PATH"

CHANGELOG=$(VERSION="$VERSION" perl -0ne '
    $version = quotemeta($ENV{VERSION});
    if (/^## $version - .*?\n\n(.*?)(?=^## \d+\.\d+\.\d+ - |\z)/ms) {
        print $1;
        exit;
    }
' "$CHANGELOG_PATH")

if [[ -z "${CHANGELOG//[$' \t\r\n']/}" ]]; then
    echo "error: failed to extract v$VERSION release notes from CHANGELOG.md"
    exit 1
fi

RELEASE_NOTES=$(printf "## What's changed\n\n%s\n\n---\n> Unsigned build - resign with [SideStore](https://sidestore.io), AltStore, or Sideloadly before installing." "$CHANGELOG")

# 8. Commit + tag (signed). Tag the release metadata first so the IPA
# build below runs from a clean tree and bakes the release commit hash
# into GitInfo instead of the pre-release parent plus a dirty marker.
# AltStore metadata is synced locally after the IPA is built, then
# committed as a follow-up on main so the published manifest cannot be
# skipped if the release succeeds.
git -C "$REPO_ROOT" add "$PROJECT_YML" \
    "$CHANGELOG_PATH"
git -C "$REPO_ROOT" commit -S -m "chore: bump version to $VERSION (build $BUILD)"
git -C "$REPO_ROOT" tag -s "v$VERSION" -m "v$VERSION"

# 9. Build unsigned .ipa from the clean release commit.
echo "==> building unsigned ipa"
BUILD_DIR="$PROJECT_DIR/build/Release-iphoneos"
rm -rf "$BUILD_DIR"
xcodebuild \
    -project "$PROJECT_DIR/Empo.xcodeproj" \
    -target Empo \
    -sdk iphoneos \
    -arch arm64 \
    -configuration Release \
    CODE_SIGNING_ALLOWED=NO \
    PRODUCT_BUNDLE_IDENTIFIER=sh.mateo.empo \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    build 2>&1 | grep -E "^(Build|error:|warning: |CompileSwift|Ld )" || true

APP_PATH="$BUILD_DIR/Empo.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build failed - Empo.app not found at $BUILD_DIR"
    exit 1
fi

"$REPO_ROOT/scripts/audit-ipa.sh" --version "$VERSION" "$APP_PATH"

echo "==> ad-hoc signing with entitlements"
codesign --force --sign - \
    --generate-entitlement-der \
    --entitlements "$PROJECT_DIR/Empo.entitlements" \
    "$APP_PATH"

mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/Empo.app"
IPA_NAME="Empo-${VERSION}-unsigned.ipa"
(cd "$IPA_DIR" && zip -qr "$IPA_NAME" Payload)
rm -rf "$IPA_DIR/Payload"
IPA_PATH="$IPA_DIR/$IPA_NAME"
IPA_SIZE=$(stat -f%z "$IPA_PATH")
echo "    ipa: $IPA_PATH ($IPA_SIZE bytes)"

# 10. Update AltStore source from the locally-built artifact so the
# manifest lands through the same signed release flow as every other
# release metadata change.
echo "==> updating altstore source"
ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin)
case "$ORIGIN_URL" in
    git@github.com:*)
        REPO_SLUG="${ORIGIN_URL#git@github.com:}"
        ;;
    https://github.com/*)
        REPO_SLUG="${ORIGIN_URL#https://github.com/}"
        ;;
    *)
        echo "error: unsupported origin URL for GitHub release assets: $ORIGIN_URL"
        exit 1
        ;;
esac
REPO_SLUG="${REPO_SLUG%.git}"
IPA_DOWNLOAD_URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION/$IPA_NAME"
RELEASE_DATE=$(date -u +%Y-%m-%d)

bun "$REPO_ROOT/scripts/update-altstore-source.ts" \
    --version "$VERSION" \
    --build "$BUILD" \
    --size "$IPA_SIZE" \
    --date "$RELEASE_DATE" \
    --download-url "$IPA_DOWNLOAD_URL" \
    --description "$CHANGELOG"

git -C "$REPO_ROOT" add "$ALTSTORE_SOURCE"
if ! git -C "$REPO_ROOT" diff --cached --quiet; then
    # Keep this follow-up commit out of future git-cliff release notes.
    git -C "$REPO_ROOT" commit -S -m "sync AltStore source for v$VERSION"
fi

# 11. Push
echo "==> pushing to origin"
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "v$VERSION"

# 12. Create GitHub release
echo "==> creating github release"
gh release create "v$VERSION" \
    --title "v$VERSION" \
    --notes "$RELEASE_NOTES" \
    "$IPA_PATH"

echo "==> done - v$VERSION released"
