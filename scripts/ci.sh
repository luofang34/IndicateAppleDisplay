#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

swift build --package-path "$repo_dir"
swift test --package-path "$repo_dir"
"$script_dir/check-corpus.sh"
