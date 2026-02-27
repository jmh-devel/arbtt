#!/usr/bin/env bash

set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script currently supports Debian/Ubuntu systems with apt-get." >&2
    exit 1
fi

if command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
        SUDO="sudo -n"
    else
        SUDO="sudo"
    fi
else
    SUDO=""
fi

${SUDO} apt-get update
${SUDO} apt-get install -y \
    build-essential \
    cabal-install \
    debhelper \
    devscripts \
    dh-exec \
    dpkg-dev \
    fakeroot \
    ghc \
    libpcre3-dev \
    libx11-dev \
    libxext-dev \
    pkg-config

echo "Debian build dependencies installed."
