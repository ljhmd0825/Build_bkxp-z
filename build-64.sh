#!/bin/bash
set -e

# 환경 설정
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
EMU_DIR="$OUTPUT_DIR/Emu/MKXP-Z"
LIB_DIR="$OUTPUT_DIR/lib"
LOGS_DIR="$OUTPUT_DIR/logs"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"

echo "=== Building mkxp-z for aarch64 (Embedded) ==="

# 1. 소스 체크아웃 및 패치 (ScummVM 방식 계승)
if [ ! -d "mkxp-z" ]; then
    git clone --recursive https://github.com/mkxp-z/mkxp-z.git mkxp-z
fi
cd mkxp-z

# 패치 적용 (patches 폴더 내 모든 .patch 적용)
if [ -d "/patches" ] && ls "/patches"/*.patch 1>/dev/null 2>&1; then
    for patch in "/patches"/*.patch; do
        echo "Applying patch: $(basename "$patch")"
        git apply "$patch"
    done
fi

# 2. 크로스 컴파일 환경 변수 (ScummVM 로직과 동일)
export CC="ccache aarch64-linux-gnu-gcc"
export CXX="ccache aarch64-linux-gnu-g++"
export AR="aarch64-linux-gnu-ar"
export STRIP="aarch64-linux-gnu-strip"
export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig"
export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig"
export CCACHE_DIR="$CCACHE_DIR"

# 3. Meson 크로스 파일 생성 (중요: Docker 내 시스템 라이브러리 참조)
cat <<EOF > cross_file.meson
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkgconfig = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'

[properties]
pkg_config_libdir = '/usr/lib/aarch64-linux-gnu/pkgconfig'
EOF

# 4. Meson 빌드 (ScummVM의 configure 단계 대체)
# -Dworkdir_use_etc=false는 임베디드 기기에서 경로 문제를 방지합니다.
rm -rf build-aarch64
meson setup build-aarch64 \
    --cross-file cross_file.meson \
    --buildtype release \
    --prefix="$EMU_DIR" \
    -Dworkdir_use_etc=false \
    -Duse_opengl=gles2 | tee "$LOGS_DIR/meson_summary.txt"

# 5. 빌드 및 설치
ninja -C build-aarch64
ninja -C build-aarch64 install

# 6. 라이브러리 수집 (ScummVM 스크립트의 핵심 로직 이식)
echo "=== Collecting shared libraries ==="
mkdir -p "$LIB_DIR"

# mkxp-z 실행에 필수적인 라이브러리 목록 (필요시 추가)
LIBS=(
    "libSDL2-2.0.so.0" "libSDL2_net-2.0.so.0" "libfluidsynth.so.3"
    "libpixman-1.so.0" "libfreetype.so.6" "libvorbisfile.so.3"
    "libvorbis.so.0" "libogg.so.0" "libexpat.so.1" "libz.so.1"
    "libbz2.so.1.0" "libpng16.so.16" "libglib-2.0.so.0" "libpcre.so.3"
    "libasound.so.2" "libstdc++.so.6" "libgcc_s.so.1"
)

for lib in "${LIBS[@]}"; do
    TARGET=$(find /usr/lib/aarch64-linux-gnu -name "$lib*" -print -quit)
    if [ -n "$TARGET" ]; then
        echo "Copying $lib..."
        cp -L "$TARGET" "$LIB_DIR/$lib"
    else
        echo "Warning: $lib not found!"
    fi
done

# 7. 패키징
cd "$OUTPUT_DIR"
BUILD_DATE=$(date +%m%d)
OUT_FILENAME="mkxp-z.aarch64.${BUILD_DATE}.7z"
7z a -t7z -m0=lzma2 -mx=9 "$OUT_FILENAME" Emu/ lib/ logs/

echo "=== Build complete: ${OUTPUT_DIR}/${OUT_FILENAME} ==="