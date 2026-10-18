#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=8.1.2
emcc --version | head -1 | grep -F "6.0.12" >/dev/null || { echo "This lab pins Emscripten 6.0.12" >&2; exit 1; }
mkdir -p third_party app/web/decoder
archive="third_party/ffmpeg-$version.tar.xz"
if [ ! -f "$archive" ]; then curl -fL --retry 2 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive"; fi
printf "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c  %s\n" "$archive" | shasum -a 256 -c -
shasum -a 256 "$archive" > work/ffmpeg-source.sha256
if [ ! -d "third_party/ffmpeg-$version" ]; then tar xf "$archive" -C third_party; fi
cd "third_party/ffmpeg-$version"
if [ ! -f ffbuild/config.mak ]; then
emconfigure ./configure --cc=emcc --cxx=em++ --ar=emar --ranlib=emranlib --nm=emnm \
 --target-os=none --arch=wasm32 --enable-cross-compile --disable-asm --disable-inline-asm \
 --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-debug \
 --disable-pthreads --disable-network --enable-small --enable-protocol=file \
 --enable-demuxer=mov --enable-parser=h264,aac --enable-decoder=h264,aac \
 --enable-encoder=mjpeg,pcm_s16le --enable-swscale --enable-swresample \
 --disable-gpl --disable-nonfree > ../../work/configure-web.log 2>&1
fi
emmake make -j4 > ../../work/build-web-libs.log 2>&1
cd ../..
emcc -O2 web_decoder/decode.c -I"third_party/ffmpeg-$version" \
 "third_party/ffmpeg-$version/libavformat/libavformat.a" \
 "third_party/ffmpeg-$version/libavcodec/libavcodec.a" \
 "third_party/ffmpeg-$version/libswresample/libswresample.a" \
 "third_party/ffmpeg-$version/libswscale/libswscale.a" \
 "third_party/ffmpeg-$version/libavutil/libavutil.a" -lm \
 -sMODULARIZE=1 -sEXPORT_NAME=createMediaDecoder -sALLOW_MEMORY_GROWTH=1 \
 -sEXPORTED_FUNCTIONS='["_open_decoder","_next_event","_close_decoder","_event_ptr","_event_size","_event_pts","_decoder_license","_decoder_config","_input_bytes_read"]' \
 -sEXPORTED_RUNTIME_METHODS='["FS","WORKERFS","ccall","HEAPU8"]' -lworkerfs.js -sFORCE_FILESYSTEM=1 \
 -sENVIRONMENT=web,worker -o app/web/decoder/decoder.js
cp web_decoder/worker.js app/web/decoder/worker.js
