#!/usr/bin/env bash
# install.sh - from WSL: run the Windows installer, then link the WSL shim into ~/.local/bin.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
win=$(wslpath -w "$here/src/Install.ps1")
(cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win" | tr -d '\r')
mkdir -p "$HOME/.local/bin"
ln -sf "$here/bin/jump-privacy" "$HOME/.local/bin/jump-privacy"
echo "WSL shim: ~/.local/bin/jump-privacy -> $here/bin/jump-privacy"
