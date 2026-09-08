#!/bin/sh
# Xcode Cloud runs this before every build phase — including the per-simulator
# test-run phases, which restore prebuilt artifacts and have NO source checkout.
# Assuming a checkout is always present is what broke build 1: `set -u` plus an
# unset CI_PRIMARY_REPOSITORY_PATH aborted the script in under a second on each
# of the four test simulators, while the same script succeeded in 6.1s during
# the build phase where the repository did exist.
set -eu

echo "Phase: ${CI_XCODEBUILD_ACTION:-unknown}"

if [ -z "${CI_PRIMARY_REPOSITORY_PATH:-}" ] || [ ! -d "${CI_PRIMARY_REPOSITORY_PATH:-}" ]; then
    echo "No source checkout in this phase; nothing to check. Exiting cleanly."
    exit 0
fi

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Checking for committed credentials..."
if [ -f Configs/Secrets.xcconfig ]; then
    echo "error: Configs/Secrets.xcconfig is present in the repository." >&2
    exit 1
fi
if grep -rEl '"mb-[A-Za-z0-9]{16,}"' MangaBaka --include='*.swift' 2>/dev/null; then
    echo "error: a token-shaped literal is present in shipping code." >&2
    exit 1
fi
echo "  no credentials committed."

# Installing the linter is infrastructure; finding a violation is a real gate.
# They are not the same failure, so they do not get the same outcome: a brew
# hiccup warns, a lint violation fails the build.
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "Installing SwiftLint..."
    brew install swiftlint || echo "warning: could not install SwiftLint; skipping lint." >&2
fi
if command -v swiftlint >/dev/null 2>&1; then
    echo "Linting..."
    swiftlint lint --strict
else
    echo "warning: SwiftLint unavailable; lint skipped in this phase." >&2
fi

# App Store Connect refuses a build number it has already seen, so every archive
# needs a unique one. Only the archive phase produces an uploadable build.
if [ -n "${CI_BUILD_NUMBER:-}" ] && [ -f project.yml ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    # project.yml is the source of truth and ci_post_clone regenerates the
    # project from it, so patch the yml rather than the generated pbxproj.
    sed -i "" "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"/" project.yml
    if command -v xcodegen >/dev/null 2>&1; then
        xcodegen generate
    else
        echo "warning: xcodegen unavailable; build number not applied to the project." >&2
    fi
    grep CURRENT_PROJECT_VERSION project.yml
fi

echo "Pre-build checks passed."
