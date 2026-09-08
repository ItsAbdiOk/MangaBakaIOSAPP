#!/bin/sh
# Xcode Cloud runs this after ci_post_clone and before building.
#
# These are the same gates the local pre-push hook enforces. They run here too
# because a push made with --no-verify, or from another machine, would otherwise
# reach TestFlight unchecked. Xcode Cloud compute is separate from GitHub
# Actions minutes.
set -eu

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

echo "Linting..."
brew install swiftlint
swiftlint lint --strict

# App Store Connect rejects a build whose number it has already seen, so every
# archive needs a unique one. Xcode Cloud supplies a monotonically increasing
# CI_BUILD_NUMBER; without wiring it in, every build would upload as "1" and the
# second one would be refused.
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    # project.yml is the source of truth and ci_post_clone regenerates the
    # project from it, so patch the yml rather than the generated pbxproj.
    sed -i "" "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$CI_BUILD_NUMBER\"/" project.yml
    xcodegen generate
    grep CURRENT_PROJECT_VERSION project.yml
else
    echo "No CI_BUILD_NUMBER (not an Xcode Cloud run); leaving the build number alone."
fi

echo "Pre-build checks passed."
