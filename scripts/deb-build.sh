#!/usr/bin/env bash

set -euo pipefail

if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
    echo "Missing required tool: dpkg-buildpackage" >&2
    echo "Run scripts/deb-install-deps.sh first." >&2
    exit 1
fi

if [[ ! -d debian ]]; then
    echo "Missing debian/ packaging metadata." >&2
    exit 1
fi

cpu_count="$(nproc)"
if [[ "${cpu_count}" -lt 1 ]]; then
    cpu_count=1
fi
export DEB_BUILD_OPTIONS="parallel=${cpu_count}"

echo "Building Debian package (binary-only)..."
dpkg-buildpackage -us -uc -b

echo "Build complete. Artifacts are in parent directory:"
echo "  ../*.deb"
echo "  ../*.changes"
echo "  ../*.buildinfo"
