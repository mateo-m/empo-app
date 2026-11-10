#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Each step of an Empo release. The Release workflow runs the same steps.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/Empo"
PROJECT_YML="$PROJECT_DIR/project.yml"
CHANGELOG_PATH="$REPO_ROOT/CHANGELOG.md"
ALTSTORE_SOURCE="$REPO_ROOT/altstore-source.json"
BUILD_ROOT="$REPO_ROOT/build"
# A fixed name, so releases/latest/download/Empo-ios.ipa always gives
# the newest one.
IPA_NAME="Empo-ios.ipa"

cd "$REPO_ROOT"

usage() {
    cat >&2 <<'USAGE'
usage: scripts/release.sh <command>

Commands for a person:
  cut [--local] <bump>    Bump the version, write the changelog, commit,
                          tag, and push. The tag push starts the Release
                          workflow, which builds and publishes the release.
                          --local builds and publishes from this computer.
  sync <version>          Write a published release into the AltStore
                          source and push it to main. Use it when the sync
                          job of the Release workflow failed.

Steps of the Release workflow. prepare, build, and altstore print key=value lines:
  prepare <bump>          Bump the version and write the changelog. No commit.
  build [version]         Build, sign, audit, and package the iPhone app and
                          the Mac app. The version defaults to project.yml.
  notes <version>         Print the notes of the GitHub release.
  altstore <version> <ipa-size>
                          Write the release into altstore-source.json.

<bump> is major, minor, patch, or a version such as 0.1.0.
GitHub can also cut a release: Actions > Release > Run workflow (mode=cut).
USAGE
    exit 1
}

log() {
    echo "$@" >&2
}

fail() {
    log "error: $*"
    exit 1
}

output() {
    printf '%s=%s\n' "$1" "$2"
}

# Reads one setting of a project.yml from stdin.
setting_in() {
    KEY="$1" perl -ne 'if (/^\s*\Q$ENV{KEY}\E: "?([^"\n]*)"?$/) { print $1; exit }'
}

project_setting() {
    setting_in "$1" <"$PROJECT_YML"
}

set_project_setting() {
    KEY="$1" VALUE="$2" perl -pi -e 's/^(\s*\Q$ENV{KEY}\E: ).*/$1$ENV{VALUE}/' "$PROJECT_YML"
}

tag_exists() {
    git rev-parse -q --verify "refs/tags/v$1" >/dev/null
}

require_clean_tree() {
    git diff --quiet HEAD || fail "the working tree has changes. Commit or stash them first"
}

# cut and sync push the local main, and next_version reads the tags.
require_current_main() {
    [[ "$(git branch --show-current)" == main ]] || fail "check out main first"
    git fetch --quiet --tags origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
        fail "main is not the same as origin/main. Pull or push first"
}

repo_slug() {
    local slug
    slug=$(git remote get-url origin | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')
    [[ "$slug" =~ ^[^/:]+/[^/:]+$ ]] || fail "origin is not a GitHub repository: $(git remote get-url origin)"
    echo "$slug"
}

# The project default ships every core. EMPO_CORES in the environment
# ships only the cores it names, for example EMPO_CORES=Psdk30Core.
release_cores() {
    echo "${EMPO_CORES:-$(project_setting EMPO_CORES)}"
}

next_version() {
    local bump="$1" latest main_version newer major minor patch
    case "$bump" in
        major | minor | patch) ;;
        *)
            [[ "$bump" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
                fail "the bump must be major, minor, patch, or a version such as 0.1.0, not: $bump"
            echo "$bump"
            return
            ;;
    esac
    latest=$(git tag --list "v*.*.*" --sort=-v:refname | head -n 1)
    if [[ -z "$latest" ]]; then
        echo "0.1.0"
        return
    fi
    latest="${latest#v}"
    # A cut whose build failed leaves its version on main with no tag.
    # The next cut releases that version, whatever the bump says.
    main_version=$(project_setting MARKETING_VERSION)
    newer=$(printf '%s\n' "$main_version" "$latest" | sort -V | tail -n 1)
    if [[ "$main_version" != "$latest" && "$newer" == "$main_version" ]]; then
        log "    main has the untagged version $main_version: releasing it again"
        echo "$main_version"
        return
    fi
    IFS=. read -r major minor patch <<<"$latest"
    case "$bump" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
    esac
}

# Sets VERSION, BUILD, and BUMP_MESSAGE.
prepare_release() {
    require_clean_tree
    command -v git-cliff >/dev/null || fail "git-cliff is required to write the changelog"
    VERSION=$(next_version "$1")
    ! tag_exists "$VERSION" || fail "tag v$VERSION already exists"
    log "==> preparing v$VERSION"

    log "==> verifying dependency pins"
    REQUIRE_PUBLISHED=1 scripts/verify-empo-deps-pins.sh >&2

    BUILD=$(git rev-list --count HEAD)
    set_project_setting MARKETING_VERSION "$VERSION"
    set_project_setting CURRENT_PROJECT_VERSION "$BUILD"
    log "    version: $VERSION, build: $BUILD"

    log "==> writing the changelog"
    # git-cliff reads the PR labels from the GitHub API. Without a token,
    # GitHub allows 60 requests an hour.
    local token
    if [[ -z "${GITHUB_TOKEN:-}" ]] && token=$(gh auth token 2>/dev/null); then
        export GITHUB_TOKEN="$token"
    fi
    scripts/changelog.sh "$VERSION" >&2
    BUMP_MESSAGE="chore: bump version to $VERSION (build $BUILD)"
}

# Sets IPA_PATH, IPA_SIZE, and DMG_PATH.
build_release() {
    local version="$1" cores products derived app ipa_dir project_version
    cores=$(release_cores)
    products="$BUILD_ROOT/Release-iphoneos"
    derived="$BUILD_ROOT/DerivedData"
    ipa_dir="$BUILD_ROOT/ipa"
    project_version=$(project_setting MARKETING_VERSION)
    [[ "$version" == "$project_version" ]] || fail "project.yml has the version $project_version, not $version"
    log "==> building v$version with the cores: $cores"

    xcodegen generate --spec "$PROJECT_YML" --project "$PROJECT_DIR" --quiet >&2
    # Xcode does not write Extensions/Empo.appexpt again when the old
    # build data says the step is done, also when the file is gone.
    rm -rf "$products" "$derived"
    # A -target build cannot find the module map of the json5cpp package,
    # so build the scheme.
    xcodebuild \
        -project "$PROJECT_DIR/Empo.xcodeproj" \
        -scheme Empo \
        -destination 'generic/platform=iOS' \
        -configuration Release \
        -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO \
        CONFIGURATION_BUILD_DIR="$products" \
        ${SENTRY_DSN:+SENTRY_DSN="$SENTRY_DSN"} \
        -xcconfig "$PROJECT_DIR/Sideload.xcconfig" \
        EMPO_CORES="$cores" \
        build 2>&1 | tail -n 40 >&2
    app="$products/Empo.app"
    [[ -d "$app" ]] || fail "the build has no Empo.app in $products"
    # The DSN comes from $SENTRY_DSN or from Signing.xcconfig.
    [[ -n "$(plutil -extract EmpoSentryDSN raw "$app/Info.plist" 2>/dev/null)" ]] ||
        fail "the app has no Sentry DSN, so it would send no error reports. Set SENTRY_DSN."

    # SideStore and AltStore give an extension in Extensions/ no new
    # bundle ID, and iOS then refuses to install the whole app.
    rm -rf "$app/Extensions"
    scripts/sign-app.sh "$app" >&2
    scripts/audit-ipa.sh --version "$version" --cores "$cores" "$app" >&2

    rm -rf "$ipa_dir"
    mkdir -p "$ipa_dir/Payload"
    cp -R "$app" "$ipa_dir/Payload/Empo.app"
    (cd "$ipa_dir" && zip -qr "$IPA_NAME" Payload)
    rm -rf "$ipa_dir/Payload"
    IPA_PATH="$ipa_dir/$IPA_NAME"
    IPA_SIZE=$(stat -f%z "$IPA_PATH")
    log "    ipa: $IPA_PATH ($IPA_SIZE bytes)"

    DMG_PATH=$(EMPO_CORES="$cores" scripts/package-mac.sh "$version" | tail -n 1)
    log "    mac: $DMG_PATH"
}

release_notes() {
    local section
    section=$(scripts/extract-changelog.sh "$1" "$CHANGELOG_PATH")
    printf "## What's changed\n\n%s\n\n---\n%s\n>\n%s\n" "$section" \
        "> iPhone and iPad: install the app with a sideloading tool. [Install Empo on an iPhone or iPad](https://empo.mateo.sh/install#iphone-and-ipad) shows how." \
        "> Mac: macOS blocks the app the first time you open it. [Install Empo on a Mac](https://empo.mateo.sh/install#mac) shows how to allow it."
}

# Sets SYNC_MESSAGE. The build number and the minimum iOS version come
# from the tag, because main can move on after the cut.
write_altstore() {
    local version="$1" ipa_size="$2" project slug build min_os notes
    project=$(git show "v$version:ios/Empo/project.yml") || fail "tag v$version not found"
    slug=$(repo_slug)
    build=$(setting_in CURRENT_PROJECT_VERSION <<<"$project")
    min_os=$(setting_in iOS <<<"$project")
    notes=$(scripts/altstore-notes.sh "$version" "$CHANGELOG_PATH")
    log "==> writing v$version into $(basename "$ALTSTORE_SOURCE")"
    bun scripts/update-altstore-source.ts \
        --version "$version" \
        --build "$build" \
        --min-os-version "$min_os" \
        --size "$ipa_size" \
        --date "$(date -u +%Y-%m-%d)" \
        --download-url "https://github.com/$slug/releases/download/v$version/$IPA_NAME" \
        --description "$notes" >&2
    # The Lint job checks the format of this file on main.
    bun x oxfmt "$ALTSTORE_SOURCE" >&2
    SYNC_MESSAGE="chore(release): sync AltStore source for v$version"
}

commit_altstore() {
    git add "$ALTSTORE_SOURCE"
    if git diff --cached --quiet; then
        log "    the AltStore source already has this release"
        return
    fi
    git commit -S -m "$SYNC_MESSAGE" >&2
}

cut_release() {
    local local_build=0
    if [[ "${1:-}" == "--local" ]]; then
        local_build=1
        shift
    fi
    [[ $# -eq 1 ]] || usage

    require_current_main
    prepare_release "$1"
    git add "$PROJECT_YML" "$CHANGELOG_PATH"
    git commit -S -m "$BUMP_MESSAGE" >&2
    git tag -s "v$VERSION" -m "v$VERSION"

    if [[ "$local_build" == 1 ]]; then
        build_release "$VERSION"
        write_altstore "$VERSION" "$IPA_SIZE"
        commit_altstore
    fi

    log "==> pushing to origin"
    git push origin main
    git push origin "v$VERSION"

    if [[ "$local_build" == 1 ]]; then
        log "==> creating the GitHub release"
        local notes
        notes=$(release_notes "$VERSION")
        gh release create "v$VERSION" --title "v$VERSION" \
            --notes "$notes" "$IPA_PATH" "$DMG_PATH"
        log "==> done: v$VERSION is released"
    else
        log "==> done: the Release workflow builds and publishes v$VERSION"
        log "    watch: gh run watch \$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
        log "    if its AltStore sync fails: $0 sync $VERSION"
    fi
}

sync_release() {
    local version="$1" size
    require_clean_tree
    require_current_main
    size=$(gh release view "v$version" --json assets \
        --jq ".assets[] | select(.name == \"$IPA_NAME\") | .size") ||
        fail "could not read the GitHub release v$version"
    [[ -n "$size" ]] || fail "the GitHub release v$version has no $IPA_NAME"
    write_altstore "$version" "$size"
    commit_altstore
    git push origin main
    log "==> done: the AltStore source has v$version"
}

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
case "$COMMAND" in
    cut)
        cut_release "$@"
        ;;
    sync)
        [[ $# -eq 1 ]] || usage
        sync_release "$1"
        ;;
    prepare)
        [[ $# -eq 1 ]] || usage
        prepare_release "$1"
        output version "$VERSION"
        output message "$BUMP_MESSAGE"
        ;;
    build)
        [[ $# -le 1 ]] || usage
        VERSION="${1:-$(project_setting MARKETING_VERSION)}"
        build_release "$VERSION"
        output version "$VERSION"
        output ipa_path "$IPA_PATH"
        output ipa_size "$IPA_SIZE"
        output dmg_path "$DMG_PATH"
        ;;
    notes)
        [[ $# -eq 1 ]] || usage
        release_notes "$1"
        ;;
    altstore)
        [[ $# -eq 2 ]] || usage
        write_altstore "$1" "$2"
        output message "$SYNC_MESSAGE"
        ;;
    *)
        usage
        ;;
esac
