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

if ! command -v dpkg-parsechangelog >/dev/null 2>&1; then
    echo "Missing required tool: dpkg-parsechangelog" >&2
    exit 1
fi

cpu_count="$(nproc)"
if [[ "${cpu_count}" -lt 1 ]]; then
    cpu_count=1
fi
export DEB_BUILD_OPTIONS="parallel=${cpu_count}"

version="$(dpkg-parsechangelog -SVersion)"
distribution="$(dpkg-parsechangelog -SDistribution)"
architecture="$(dpkg --print-architecture)"

artifact_root="build/artifacts/debian/ubuntu/${distribution}/${architecture}/${version}"
latest_root="build/artifacts/debian/ubuntu/${distribution}/${architecture}/latest"

mkdir -p "${artifact_root}" "${latest_root}"
find "${latest_root}" -type f -delete

echo "Building Debian package (binary-only)..."
dpkg-buildpackage -us -uc -b

declare -a candidates=(
    "../arbtt_${version}_${architecture}.deb"
    "../arbtt-dbgsym_${version}_${architecture}.ddeb"
    "../arbtt_${version}_${architecture}.changes"
    "../arbtt_${version}_${architecture}.buildinfo"
)

copied=0
for file in "${candidates[@]}"; do
    if [[ -f "${file}" ]]; then
        cp -f "${file}" "${artifact_root}/"
        cp -f "${file}" "${latest_root}/"
        copied=1
    fi
done

if [[ "${copied}" -eq 0 ]]; then
    echo "Warning: no expected artifacts were found in parent directory." >&2
    exit 1
fi

(cd "${artifact_root}" && sha256sum ./* >SHA256SUMS)
(cd "${latest_root}" && sha256sum ./* >SHA256SUMS)

echo "Build complete. Artifacts copied to:"
echo "  ${artifact_root}"
echo "  ${latest_root}"
