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
    echo "       $0 --sync-only <version>"
    echo "  bump   major | minor | patch     bump latest tag's segment"
    echo "         <semver>                  explicit version (e.g. 0.1.0)"
    echo ""
    echo "Default flow (single command; CI builds, this script finishes):"
    echo "  1. verifies empo-deps pins"
    echo "  2. bumps version, generates the changelog, commits, tags"
    echo "     (v<version> here + empo-v<version> on the engine repo)"
    echo "  3. pushes; the Release workflow builds, audits, and"
    echo "     publishes the IPA"
    echo "  4. waits for the published IPA + engine artifact, then"
    echo "     syncs the AltStore manifest + engine pin and pushes"
    echo "     them straight to main (signed, no PR)"
    echo ""
    echo "--sync-only <version>   re-run step 4 for an already-cut tag"
    echo "                        (resume after an interrupt or a CI retry)"
    echo ""
    echo "RELEASE_LOCAL_BUILD=1   build/audit/sign/publish locally instead"
    echo "                        (fallback for when CI is unavailable)"
    echo "RELEASE_REBUILD_DEPS=1  rebuild native deps from source first"
    echo "                        (implies RELEASE_LOCAL_BUILD=1)"
    exit 1
}

SYNC_ONLY=0
if [[ "${1:-}" == "--sync-only" ]]; then
    SYNC_ONLY=1
    shift
fi
[[ $# -ne 1 ]] && usage
BUMP_OR_VERSION="$1"

# Resolve the GitHub "owner/repo" slug from the origin remote so
# release assets can be addressed by URL.
repo_slug() {
    local origin_url slug
    origin_url=$(git -C "$REPO_ROOT" remote get-url origin)
    case "$origin_url" in
        git@github.com:*)
            slug="${origin_url#git@github.com:}"
            ;;
        https://github.com/*)
            slug="${origin_url#https://github.com/}"
            ;;
        *)
            echo "error: unsupported origin URL for GitHub release assets: $origin_url" >&2
            exit 1
            ;;
    esac
    printf '%s' "${slug%.git}"
}

# Step 4 of the default flow: wait for the Release workflow's
# published IPA and the fork's engine artifact, then update the
# AltStore manifest + engine pin and push both straight to main.
# Runs locally under the operator's credentials on purpose: main's
# ruleset requires reviewed PRs from bot identities, but a direct
# admin push with a signed commit completes the release without a
# manual approval step.
run_ci_sync() {
    local version="$1"
    local ipa_name="Empo-${version}-unsigned.ipa"
    local engine_tag="empo-v$version"
    local engine_repo="mateo-m/mkxp-z-apple-mobile"
    local i

    echo "==> waiting for the Release workflow to publish $ipa_name"
    local ipa_size=""
    for i in $(seq 1 120); do
        ipa_size=$(gh release view "v$version" --json assets \
            --jq ".assets[] | select(.name == \"$ipa_name\") | .size" 2>/dev/null || true)
        [[ -n "$ipa_size" ]] && break
        local run_status
        run_status=$(gh run list --workflow=release.yml --branch "v$version" --limit 1 \
            --json status,conclusion --jq '.[0] | .status + ":" + (.conclusion // "")' 2>/dev/null || true)
        if [[ "$run_status" == completed:* && "$run_status" != "completed:success" ]]; then
            echo "error: Release workflow finished without publishing ($run_status)"
            echo "       fix and re-run it, then resume with: $0 --sync-only $version"
            exit 1
        fi
        if [[ "$i" -eq 120 ]]; then
            echo "error: timed out waiting for $ipa_name on release v$version"
            echo "       resume with: $0 --sync-only $version"
            exit 1
        fi
        sleep 30
    done
    echo "    ipa published ($ipa_size bytes)"

    echo "==> waiting for engine artifact $engine_tag"
    local engine_status
    for i in $(seq 1 60); do
        engine_status=$(gh run list --repo "$engine_repo" --branch "$engine_tag" \
            --workflow engine-artifacts --limit 1 \
            --json status,conclusion \
            --jq '.[0] | .status + ":" + (.conclusion // "")' 2>/dev/null || true)
        case "$engine_status" in
            completed:success) break ;;
            completed:*)
                echo "error: engine artifact build failed ($engine_status)"
                echo "       fix and re-run it, then resume with: $0 --sync-only $version"
                exit 1
                ;;
        esac
        if [[ "$i" -eq 60 ]]; then
            echo "error: timed out waiting for the engine artifact"
            echo "       resume with: $0 --sync-only $version"
            exit 1
        fi
        sleep 30
    done

    echo "==> re-pinning engine prebuilt to $engine_tag"
    local engine_tarball sha256
    engine_tarball=$(mktemp)
    curl -fsSL --retry 3 -o "$engine_tarball" \
        "https://github.com/$engine_repo/releases/download/$engine_tag/engine-ios-prebuilt.tar.gz"
    sha256=$(shasum -a 256 "$engine_tarball" | awk '{print $1}')
    rm -f "$engine_tarball"
    local pin="$REPO_ROOT/ios/Dependencies/engine/.version"
    sed -i '' "s/^ENGINE_VERSION=.*/ENGINE_VERSION=$engine_tag/" "$pin"
    sed -i '' "s/^ENGINE_SHA256=.*/ENGINE_SHA256=$sha256/" "$pin"

    echo "==> syncing altstore source"
    local slug changelog build release_date
    slug=$(repo_slug)
    changelog=$("$REPO_ROOT/scripts/extract-changelog.sh" "$version" "$CHANGELOG_PATH")
    build=$(sed -n 's/.*CURRENT_PROJECT_VERSION: //p' "$PROJECT_YML" | head -n 1)
    release_date=$(date -u +%Y-%m-%d)
    bun "$REPO_ROOT/scripts/update-altstore-source.ts" \
        --version "$version" \
        --build "$build" \
        --size "$ipa_size" \
        --date "$release_date" \
        --download-url "https://github.com/$slug/releases/download/v$version/$ipa_name" \
        --description "$changelog"
    # The Format gate (oxfmt) checks this file on main; keep the
    # generated manifest formatted so the gate stays green.
    bunx oxfmt "$ALTSTORE_SOURCE"

    git -C "$REPO_ROOT" add "$ALTSTORE_SOURCE" "$pin"
    if git -C "$REPO_ROOT" diff --cached --quiet; then
        echo "    manifest and pin already in sync"
        return 0
    fi
    git -C "$REPO_ROOT" commit -S -m "chore(release): sync AltStore source and engine pin for v$version"
    git -C "$REPO_ROOT" push origin main
    echo "==> done - v$version fully released"
}

# Rebuilding deps from source only makes sense when the IPA is also
# built here — CI always hydrates from published pins.
if [[ "${RELEASE_REBUILD_DEPS:-0}" == "1" ]]; then
    RELEASE_LOCAL_BUILD=1
fi
LOCAL_BUILD="${RELEASE_LOCAL_BUILD:-0}"

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

if [[ "$SYNC_ONLY" == "1" ]]; then
    if ! git -C "$REPO_ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
        echo "error: tag v$VERSION not found; --sync-only resumes an already-cut release"
        exit 1
    fi
    if ! git -C "$REPO_ROOT" diff --quiet HEAD; then
        echo "error: working tree is dirty - commit or stash changes first"
        exit 1
    fi
    run_ci_sync "$VERSION"
    exit 0
fi

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

# 2. Verify dependency pins resolve to published empo-deps releases —
# even for CI builds, so an unpublished pin aborts before anything is
# tagged. Hydration/rebuild only happens for local builds; the Release
# workflow hydrates its own runner.
echo "==> verifying empo-deps pins"
if [ "${RELEASE_REBUILD_DEPS:-0}" = "1" ]; then
    REQUIRE_PUBLISHED=0 "$REPO_ROOT/scripts/verify-empo-deps-pins.sh"
else
    REQUIRE_PUBLISHED=1 "$REPO_ROOT/scripts/verify-empo-deps-pins.sh"
fi

if [[ "$LOCAL_BUILD" == "1" ]]; then
    if [ "${RELEASE_REBUILD_DEPS:-0}" = "1" ]; then
        echo "==> rebuilding device native deps from source (RELEASE_REBUILD_DEPS=1)"
        "$REPO_ROOT/scripts/rebuild-device-deps.sh"
    else
        echo "==> hydrating native deps from empo-deps"
        rm -rf "$REPO_ROOT/ios/Dependencies/build-iphoneos-arm64" \
            "$REPO_ROOT/ios/Dependencies/native/.fetched-version"
        sh "$REPO_ROOT/tools/fetch-native-deps.sh"
        sh "$REPO_ROOT/tools/fetch-engine-prebuilt.sh"
    fi
    "$REPO_ROOT/scripts/verify-device-deps.sh"
fi

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

CHANGELOG=$("$REPO_ROOT/scripts/extract-changelog.sh" "$VERSION" "$CHANGELOG_PATH")

RELEASE_NOTES=$(printf "## What's changed\n\n%s\n\n---\n> Unsigned build - sign the app with [SideStore](https://sidestore.io), [AltStore (Classic)](https://altstore.io), or [Sideloadly](https://sideloadly.io) before installing." "$CHANGELOG")

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

# 8b. Tag the engine submodule commit this release pins, so the GPL
# binary->source correspondence is provable per release: anyone can
# check out mkxp-z-apple-mobile at empo-v<version> and get exactly the
# engine source compiled into the shipped .ipa. Created locally here
# (before anything is pushed) so a failure aborts the release cleanly;
# pushed alongside the app tag in step 11.
ENGINE_TAG="empo-v$VERSION"
ENGINE_DIR="$REPO_ROOT/mkxp-z-apple-mobile"
ENGINE_COMMIT="$(git -C "$REPO_ROOT" rev-parse "HEAD:mkxp-z-apple-mobile")"
if git -C "$ENGINE_DIR" rev-parse -q --verify "refs/tags/$ENGINE_TAG" >/dev/null; then
    echo "error: engine tag $ENGINE_TAG already exists"
    exit 1
fi
git -C "$ENGINE_DIR" fetch -q origin dev
if ! git -C "$ENGINE_DIR" merge-base --is-ancestor "$ENGINE_COMMIT" origin/dev; then
    echo "error: pinned engine commit $ENGINE_COMMIT is not on mkxp-z-apple-mobile origin/dev"
    echo "       push the submodule first (policy: gitlink must be an ancestor of origin/dev)"
    exit 1
fi
git -C "$ENGINE_DIR" tag -s "$ENGINE_TAG" "$ENGINE_COMMIT" -m "Engine pinned by Empo v$VERSION"

# 9-10. Local build + AltStore sync — fallback path only. On the
# default flow the Release workflow builds, audits, and publishes the
# IPA, and run_ci_sync (called after the push below) finishes the
# release by syncing the manifest + engine pin from here.
if [[ "$LOCAL_BUILD" == "1" ]]; then

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

fi # LOCAL_BUILD

# 11. Push. On the default flow this is the handoff: the v tag
# triggers the Release workflow, and the empo-v tag triggers the
# engine repo's artifact workflow.
echo "==> pushing to origin"
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "v$VERSION"
git -C "$ENGINE_DIR" push origin "$ENGINE_TAG"

if [[ "$LOCAL_BUILD" == "1" ]]; then
    # 12. Create GitHub release from the locally-built artifact.
    echo "==> creating github release"
    gh release create "v$VERSION" \
        --title "v$VERSION" \
        --notes "$RELEASE_NOTES" \
        "$IPA_PATH"
    echo "==> done - v$VERSION released (local build)"
else
    echo "==> handed off to CI - waiting to finish the release"
    echo "    (safe to interrupt; resume later with: $0 --sync-only $VERSION)"
    run_ci_sync "$VERSION"
fi
