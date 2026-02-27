#!/usr/bin/env bash

set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script currently supports Debian/Ubuntu systems with apt-get." >&2
    exit 1
fi

sudo apt-get update
sudo apt-get install -y \
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
