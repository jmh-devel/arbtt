#!/usr/bin/env bash

set -euo pipefail

require_tool() {
    local tool="$1"
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Missing required tool: ${tool}" >&2
        echo "Install it and retry." >&2
        exit 1
    fi
}

collect_staged_files() {
    git diff --cached --name-only --diff-filter=ACMR | while read -r file; do
        if [[ -z "${file}" ]]; then
            continue
        fi
        if [[ "${file}" == scripts/*.sh || "${file}" == .githooks/* ]]; then
            if [[ -f "${file}" ]]; then
                echo "${file}"
            fi
        fi
    done
}

collect_all_files() {
    find scripts .githooks -type f \( -name "*.sh" -o -path ".githooks/*" \) | sort
}

main() {
    require_tool shellcheck
    require_tool shfmt

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
        echo "No matching shell/hook files to lint."
        exit 0
    fi

    echo "Running shfmt check..."
    shfmt -d -i 4 -ci "${files[@]}"

    echo "Running shellcheck..."
    shellcheck "${files[@]}"

    echo "Lint checks passed."
}

main "$@"
