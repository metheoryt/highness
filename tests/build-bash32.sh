#!/usr/bin/env bash
# Builds a static bash 3.2.57 (the bash macOS ships) for tests/run.sh --bash, in a Debian
# container: the release's patched parse.y needs bison, and old C needs -std=gnu89 with today's
# warnings-as-errors turned back into warnings. Static, so it runs on any x86-64 Linux host.
#
# Usage: bash tests/build-bash32.sh <dest-dir>     → <dest-dir>/bash
# Needs docker and network access (ftp.gnu.org, the Debian image and its packages).
set -euo pipefail
[ $# -eq 1 ] || { echo 'usage: tests/build-bash32.sh <dest-dir>' >&2; exit 2; }
command -v docker >/dev/null || { echo 'build-bash32: needs docker' >&2; exit 1; }
mkdir -p "$1"; dest=$(cd "$1" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/bash32.XXXXXX"); trap 'rm -rf "$work"' EXIT
curl -fsSL https://ftp.gnu.org/gnu/bash/bash-3.2.57.tar.gz | tar xz -C "$work"
docker run --rm -v "$work/bash-3.2.57:/src" -w /src debian:bookworm sh -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq gcc make bison >/dev/null 2>&1 &&
  CC="gcc -std=gnu89" CFLAGS="-O2 -Wno-implicit-function-declaration -Wno-implicit-int -Wno-incompatible-pointer-types -Wno-int-conversion" \
    ./configure -q --without-bash-malloc --enable-static-link >/dev/null &&
  make -s -j4 >/dev/null 2>&1 && cp bash /src/bash.out && chown '"$(id -u):$(id -g)"' /src/bash.out'
cp "$work/bash-3.2.57/bash.out" "$dest/bash"
"$dest/bash" -c 'echo "built bash $BASH_VERSION: '"$dest"'/bash"'
