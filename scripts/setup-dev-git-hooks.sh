#!/usr/bin/env bash

set -euo pipefail

git config core.hooksPath .githooks
git config pull.rebase true
git config rebase.autoStash true

if git show-ref --verify --quiet refs/heads/master && git remote get-url upstream >/dev/null 2>&1; then
    if git show-ref --verify --quiet refs/remotes/upstream/master; then
        git branch --set-upstream-to=upstream/master master >/dev/null
    elif git show-ref --verify --quiet refs/remotes/upstream/main; then
        git branch --set-upstream-to=upstream/main master >/dev/null
    fi
fi

if git show-ref --verify --quiet refs/heads/main; then
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        git branch --set-upstream-to=origin/main main >/dev/null
    fi
fi

chmod +x scripts/git-sync-upstream.sh scripts/setup-dev-git-hooks.sh scripts/lint.sh scripts/format.sh scripts/haskell-lint.sh scripts/haskell-format.sh scripts/deb-install-deps.sh scripts/deb-build.sh .githooks/pre-commit .githooks/pre-push

echo "Configured hooks, rebase defaults, branch upstream tracking (when available), and executable bits."
