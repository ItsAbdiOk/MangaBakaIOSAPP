#!/bin/sh
# Xcode Cloud runs this after cloning, before building.
#
# The .xcodeproj is committed, so this is belt and braces: it guarantees the
# project matches project.yml even if someone committed a stale one.
set -eu

echo "Installing XcodeGen..."
brew install xcodegen

echo "Generating the Xcode project from project.yml..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

echo "Done."
