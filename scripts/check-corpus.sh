#!/usr/bin/env bash
# Fails when the vendored conformance corpus differs from upstream.
#
# The value of pinning a corpus is that regenerating it upstream turns this
# repository red. A vendored copy cannot do that by itself, so this check needs
# a Indicate checkout: point INDICATE_DIR at one, or keep it beside this repo.
# Without a checkout the upstream comparison is skipped, unless
# CORPUS_REQUIRE_UPSTREAM is set — then a missing checkout is a failure, which
# is what the scheduled drift sentinel wants.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
fixture="$repo_dir/Tests/IndicateAppleDisplayTests/Fixtures/scene-conformance-corpus.json"
record="$fixture.source"

read_field() { sed -n "s/^$1=//p" "$record"; }

expected_sha="$(read_field sha256)"
pinned_rev="$(read_field revision)"
upstream_path="$(read_field path)"

actual_sha="$(shasum -a 256 "$fixture" | cut -d' ' -f1)"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "corpus fixture does not match its provenance record" >&2
    echo "  recorded: $expected_sha" >&2
    echo "  on disk : $actual_sha" >&2
    echo "Edit the corpus upstream and re-run scripts/sync-corpus.sh." >&2
    exit 1
fi

indicate_dir="${INDICATE_DIR:-$repo_dir/../Indicate}"
if [[ ! -d "$indicate_dir/.git" ]]; then
    if [[ -n "${CORPUS_REQUIRE_UPSTREAM:-}" ]]; then
        echo "no Indicate checkout at $indicate_dir, and CORPUS_REQUIRE_UPSTREAM" >&2
        echo "is set, so the upstream comparison is mandatory. Set INDICATE_DIR" >&2
        echo "to a Indicate checkout." >&2
        exit 1
    fi
    echo "SKIPPED the upstream comparison: no Indicate checkout at $indicate_dir." >&2
    echo "Only the vendored copy's integrity was checked. Set INDICATE_DIR to" >&2
    echo "verify that upstream has not regenerated the corpus." >&2
    exit 0
fi

if ! git -C "$indicate_dir" cat-file -e "$pinned_rev^{commit}" 2>/dev/null; then
    echo "pinned revision $pinned_rev is not in $indicate_dir; fetch it first" >&2
    exit 1
fi

pinned_sha="$(git -C "$indicate_dir" show "$pinned_rev:$upstream_path" | shasum -a 256 | cut -d' ' -f1)"
if [[ "$pinned_sha" != "$expected_sha" ]]; then
    echo "the pinned revision's corpus is not the one vendored here" >&2
    exit 1
fi

head_sha="$(git -C "$indicate_dir" show "HEAD:$upstream_path" | shasum -a 256 | cut -d' ' -f1)"
if [[ "$head_sha" != "$expected_sha" ]]; then
    echo "upstream has regenerated the conformance corpus" >&2
    echo "  vendored (rev $pinned_rev): $expected_sha" >&2
    echo "  upstream HEAD            : $head_sha" >&2
    echo "Run scripts/sync-corpus.sh, review the diff, and update the pinned" >&2
    echo "corpusVersion and corpusSha256 in ConformanceTests.swift." >&2
    exit 1
fi

echo "corpus matches upstream HEAD ($expected_sha)"
