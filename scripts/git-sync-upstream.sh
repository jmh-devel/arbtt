#!/usr/bin/env bash

set -euo pipefail

branch="$(git rev-parse --abbrev-ref HEAD)"

if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "No 'upstream' remote configured; skipping sync." >&2
    exit 0
fi

if git show-ref --verify --quiet "refs/remotes/upstream/master"; then
    upstream_ref="upstream/master"
elif git show-ref --verify --quiet "refs/remotes/upstream/main"; then
    upstream_ref="upstream/main"
else
    echo "Unable to detect upstream default branch (expected upstream/master or upstream/main)." >&2
    exit 1
fi

echo "Fetching upstream..."
git fetch upstream --prune

echo "Resetting local parity branch 'master' to ${upstream_ref}..."
git branch -f master "${upstream_ref}" >/dev/null

if [[ "${branch}" == "master" ]]; then
    echo "master is now aligned to ${upstream_ref}."
elif [[ "${branch}" == "main" ]]; then
    read -r ahead behind < <(git rev-list --left-right --count "HEAD...master")
    if [[ "${behind}" -eq 0 ]]; then
        echo "main already includes latest master (ahead=${ahead}, behind=${behind})."
    else
        echo "Rebasing main onto master (ahead=${ahead}, behind=${behind})..."
        git rebase --autostash master
    fi
else
    echo "Current branch is '${branch}'."
    echo "Rebasing '${branch}' onto master to keep feature work current..."
    git rebase --autostash master
fi

if [[ "${1:-}" == "--push" ]]; then
    echo "Pushing '${branch}' to origin with force-with-lease..."
    git push --force-with-lease origin "${branch}"
fi
