#!/bin/sh
# Stamps the SDK version into Sources/PurseHeadlessCheckout/Core/SDKVersion.swift.
#
# The version lives in exactly one place: the git tag. There is no version field in Package.swift to
# drift out of sync, and release-please only ever moves the tag and the manifest. A local build gets
# `0.0.0-SNAPSHOT`, which is also what is checked in, so a dirty working tree after a local build is
# a real change and not this script's noise.
#
# Usage: scripts/generate-version.sh [version]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/Sources/PurseHeadlessCheckout/Core/SDKVersion.swift"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  # `--dirty` matters: without it a build from a modified tree sitting on v1.2.0 stamps
  # SDKVersion.value = "1.2.0" and mis-attributes every monitoring event to a release that was
  # never cut. The suffix makes such a build self-identify instead.
  VERSION="$(git -C "$ROOT" describe --tags --exact-match --dirty=-dirty 2>/dev/null || echo "0.0.0-SNAPSHOT")"
fi
VERSION="${VERSION#v}"

cat > "$TARGET" <<SWIFT
// Generated at build time from the git tag — see scripts/generate-version.sh.
// The checked-in value is the local-build placeholder; a release build overwrites it.

import Foundation

/// The SDK version this app was built against, stamped on every monitoring event.
public enum SDKVersion {
    public static let value = "$VERSION"
}
SWIFT

echo "SDKVersion.value = $VERSION"
