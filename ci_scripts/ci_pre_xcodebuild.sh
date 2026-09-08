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

echo "Pre-build checks passed."
