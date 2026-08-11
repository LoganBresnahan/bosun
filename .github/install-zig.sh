#!/bin/sh
# Install a PINNED Zig from ziglang.org with sha256 verification — no
# third-party action in the supply chain. Checksums are pinned per release
# below; bumping ZIG_VERSION means re-pinning all four from
# https://ziglang.org/download/index.json (the `shasum` fields).
set -eu

ZIG_VERSION="${ZIG_VERSION:-0.15.2}"

arch="$(uname -m)"; case "$arch" in arm64) arch=aarch64 ;; esac
case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *) echo "install-zig: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
target="${arch}-${os}"

case "${ZIG_VERSION}-${target}" in
    0.15.2-x86_64-linux)   sha=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
    0.15.2-aarch64-linux)  sha=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f ;;
    0.15.2-x86_64-macos)   sha=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
    0.15.2-aarch64-macos)  sha=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
    *) echo "install-zig: no pinned checksum for ${ZIG_VERSION}-${target} — re-pin from ziglang.org/download/index.json" >&2; exit 1 ;;
esac

name="zig-${target}-${ZIG_VERSION}"
curl -fsSL --retry 3 -o "/tmp/${name}.tar.xz" "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"
echo "${sha}  /tmp/${name}.tar.xz" | sha256sum -c - >/dev/null 2>&1 \
    || { echo "${sha}  /tmp/${name}.tar.xz" | shasum -a 256 -c -; }   # macOS has shasum, not sha256sum

mkdir -p "${HOME}/.zig"
tar -xJf "/tmp/${name}.tar.xz" -C "${HOME}/.zig" --strip-components=1
echo "${HOME}/.zig" >> "${GITHUB_PATH:-/dev/stdout}"
"${HOME}/.zig/zig" version
