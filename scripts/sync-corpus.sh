#!/usr/bin/env bash
# Copies the conformance corpus from a Indicate checkout and records where it
# came from. Syncing is a reviewed action: this leaves a diff to read, and the
# pinned expectations in ConformanceTests.swift still have to be updated by
# hand so a moved target cannot silently re-baseline this backend.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
fixture="$repo_dir/Tests/InstrumentSceneKitTests/Fixtures/scene-conformance-corpus.json"
record="$fixture.source"

indicate_dir="${1:-${INDICATE_DIR:-$repo_dir/../Indicate}}"
if [[ ! -d "$indicate_dir/.git" ]]; then
    echo "usage: $0 [path-to-Indicate-checkout]" >&2
    exit 1
fi

upstream_path="$(sed -n 's/^path=//p' "$record")"
revision="$(git -C "$indicate_dir" rev-parse HEAD)"

git -C "$indicate_dir" show "HEAD:$upstream_path" > "$fixture"
sha="$(shasum -a 256 "$fixture" | cut -d' ' -f1)"

tmp="$(mktemp)"
sed -e "s/^revision=.*/revision=$revision/" -e "s/^sha256=.*/sha256=$sha/" "$record" > "$tmp"
mv "$tmp" "$record"

corpus_version="$(sed -n 's/.*"corpusVersion" *: *\([0-9]*\).*/\1/p' "$fixture" | head -1)"
echo "synced from $revision"
echo "  sha256        : $sha"
echo "  corpusVersion : $corpus_version"
echo
echo "Next: review the fixture diff, then update expectedCorpusVersion,"
echo "expectedCorpusSha256, and the entry counts in ConformanceTests.swift."
