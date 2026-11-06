#!/usr/bin/env bash
# Builds libdatachannel (data channels only: no media, no WebSocket) as a
# shared library into build/libdatachannel/out. macOS uses Homebrew OpenSSL 3;
# Linux uses the system OpenSSL (libssl-dev).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
version=${LIBDATACHANNEL_VERSION:-v0.24.6}
src=$here/build/libdatachannel/src
if [ ! -d "$src" ]; then
  git clone -q --depth 1 --branch "$version" --recurse-submodules --shallow-submodules \
    https://github.com/paullouisageneau/libdatachannel.git "$src"
fi
extra=()
if [ "$(uname)" = Darwin ]; then extra=(-DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"); fi
cmake -S "$src" -B "$here/build/libdatachannel/cmake" -DCMAKE_BUILD_TYPE=Release \
  -DNO_MEDIA=ON -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON "${extra[@]}" >/dev/null
cmake --build "$here/build/libdatachannel/cmake" --target datachannel -j 8 >/dev/null
mkdir -p "$here/build/libdatachannel/out"
cp -L "$here"/build/libdatachannel/cmake/libdatachannel.*{dylib,so}* "$here/build/libdatachannel/out/" 2>/dev/null || true


# The callback shim (native/ldc_shim.c), linked against the library above.
out=$here/build/libdatachannel/out
if [ "$(uname)" = Darwin ]; then
  cc -O2 -shared -fPIC -I"$src/include" "$here/native/ldc_shim.c" -L"$out" -ldatachannel \
    -Wl,-rpath,@loader_path -o "$out/libldc_shim.dylib"
else
  cc -O2 -shared -fPIC -I"$src/include" "$here/native/ldc_shim.c" -L"$out" -ldatachannel \
    -Wl,-rpath,'$ORIGIN' -o "$out/libldc_shim.so"
fi
ls -l "$out"
