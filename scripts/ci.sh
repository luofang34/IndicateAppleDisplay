#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

swift build --package-path "$repo_dir"
swift test --package-path "$repo_dir"

# The gallery's headless path is the smoke test for the sample: it renders a
# valid and a rejected case and verifies their typed outcomes.
gallery_dir="$(mktemp -d)"
trap 'rm -rf "$gallery_dir"' EXIT
swift run --package-path "$repo_dir" BackendGallery \
    --corpus "$repo_dir/Tests/IndicateAppleDisplayTests/Fixtures/scene-conformance-corpus.json" \
    --export "$gallery_dir"

"$script_dir/check-corpus.sh"
