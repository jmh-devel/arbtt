#!/usr/bin/env bash

set -euo pipefail

pick_formatter() {
    if command -v fourmolu >/dev/null 2>&1; then
        echo "fourmolu"
        return
    fi
    if command -v ormolu >/dev/null 2>&1; then
        echo "ormolu"
        return
    fi
    echo "Missing required formatter: install 'fourmolu' (preferred) or 'ormolu'." >&2
    exit 1
}

collect_staged_files() {
    git diff --cached --name-only --diff-filter=ACMR | while read -r file; do
        if [[ -z "${file}" ]]; then
            continue
        fi
        if [[ "${file}" == *.hs || "${file}" == *.hsc ]]; then
            if [[ -f "${file}" ]]; then
                echo "${file}"
            fi
        fi
    done
}

collect_all_files() {
    find src tests -type f \( -name "*.hs" -o -name "*.hsc" \) | sort
}

main() {
    local mode="${1:-}"
    local files=()

    if [[ "${mode}" == "--staged" ]]; then
        while read -r file; do
            files+=("${file}")
        done < <(collect_staged_files)
    else
        while read -r file; do
            files+=("${file}")
        done < <(collect_all_files)
    fi

    if [[ "${#files[@]}" -eq 0 ]]; then
        echo "No matching Haskell files to format."
        exit 0
    fi

    local formatter
    formatter="$(pick_formatter)"

    echo "Formatting Haskell with ${formatter}..."
    "${formatter}" --mode inplace "${files[@]}"
    echo "Formatted ${#files[@]} Haskell files."
}

main "$@"
