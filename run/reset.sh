#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL=$(uname -r | cut -b 1)
MINOR=$(uname -r | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
VERS=$(qemu-system-x86_64 --version | head -n 1 | cut -d '(' -f 1)

rm -f /run/dsm.url
rm -f /run/qemu.pid
rm -f /run/qemu.count
