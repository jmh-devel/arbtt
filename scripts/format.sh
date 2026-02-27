#!/usr/bin/env bash

set -euo pipefail

if ! command -v shfmt >/dev/null 2>&1; then
    echo "Missing required tool: shfmt" >&2
    exit 1
fi

files=()
while read -r file; do
    files+=("${file}")
done < <(find scripts .githooks -type f \( -name "*.sh" -o -path ".githooks/*" \) | sort)

if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No matching shell/hook files to format."
    exit 0
fi

shfmt -w -i 4 -ci "${files[@]}"
echo "Formatted ${#files[@]} files."

if [[ -x scripts/haskell-format.sh ]]; then
    if command -v fourmolu >/dev/null 2>&1 || command -v ormolu >/dev/null 2>&1; then
        scripts/haskell-format.sh
    else
        echo "Skipping Haskell format (install fourmolu or ormolu to enable)."
    fi
fi
