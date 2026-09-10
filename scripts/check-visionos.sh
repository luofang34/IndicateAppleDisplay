#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Compilation checks platform availability that macOS unit tests cannot exercise.
xcodebuild -scheme IndicateAppleDisplay -destination 'generic/platform=visionOS Simulator' \
    -derivedDataPath "${INDICATE_VISION_BUILD_DIR:-/tmp/indicate-visionos-build}" \
    CODE_SIGNING_ALLOWED=NO build
