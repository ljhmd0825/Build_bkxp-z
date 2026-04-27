#!/bin/bash
set -e

# 0. 경로 환경 변수 강제 설정 (Meson/Ninja 인식 문제 해결)
# pip3로 설치된 도구들의 경로를 최우선으로 잡습니다.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:$PATH"

# 환경 설정
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
EMU_DIR="$OUTPUT_DIR/Emu/MKXP-Z"
LIB_DIR="$OUTPUT_DIR/lib"
LOGS_DIR="$OUTPUT_DIR/logs"
CCACHE_DIR="${CCACHE_DIR:-/ccache}"

# 로그 폴더 미리 생성
mkdir -p "$LOGS_DIR"

echo "=== Building mkxp-z for aarch64 (Embedded) ==="

# 1. 소스 체크아웃 및 패치
if [ ! -d "mkxp-z" ]; then
    # --recursive 필수: 하위 서브모듈(static-libs 등)까지 가져와야 함
    git clone --recursive https://github.com/mkxp-z/mkxp-z.git mkxp-z
fi
cd mkxp-z

# 패치 적용 (patches 폴더 내 모든 .patch 및 .py 적용)
if [ -d "/patches" ]; then
    # .patch 파일 적용
    if ls "/patches"/*.patch 1>/dev/null 2>&1; then
        for patch in "/patches"/*.patch; do
            echo "Applying patch: $(basename "$patch")"
            git apply "$patch"
        done
    fi
    # .py 파일(파이썬 패치) 적용
    if ls "/patches"/*.py 1>/dev/null 2>&1; then
        for patch in "/patches"/*.py; do
            echo "Applying python patch: $(basename "$patch")"
            python3 "$patch"
        done
    fi
fi

# 2. 크로스 컴파일 환경 변수
export CC="ccache aarch64-linux-gnu-gcc"
export CXX="ccache aarch64-linux-gnu-g++"
export AR="aarch64-linux-gnu-ar"
export STRIP="aarch64-linux-gnu-strip"
export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig"
export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig"
export CCACHE_DIR="$CCACHE_DIR"

# 3. Meson 크로스 파일 생성
# Docker 내부의 arm64 전용 라이브러리 경로를 명시적으로 찌릅니다.
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

# 4. Meson 빌드 설정 (mkxp-z 전용 옵션으로 수정)
rm -rf build-aarch64
meson setup build-aarch64 \
    --cross-file cross_file.meson \
    --buildtype release \
    --prefix="$EMU_DIR" \
    -Dshared_ruby=true \
    -Dstatic_libphysfs=true | tee "$LOGS_DIR/meson_summary.txt"

# 5. 빌드 및 설치
ninja -C build-aarch64
ninja -C build-aarch64 install

# 6. 라이브러리 수집 (ScummVM 로직 이식)
echo "=== Collecting shared libraries ==="
mkdir -p "$LIB_DIR"

# mkxp-z 실행에 필수적인 라이브러리 목록 (확인된 의존성 위주)
LIBS=(
    "libSDL2-2.0.so.0" "libSDL2_net-2.0.so.0" "libfluidsynth.so.3"
    "libpixman-1.so.0" "libfreetype.so.6" "libvorbisfile.so.3"
    "libvorbis.so.0" "libogg.so.0" "libexpat.so.1" "libz.so.1"
    "libbz2.so.1.0" "libpng16.so.16" "libglib-2.0.so.0" "libpcre.so.3"
    "libasound.so.2" "libstdc++.so.6" "libgcc_s.so.1"
    "libruby.so.3.1" "libcrypto.so.1.1" "libssl.so.1.1"
)

for lib in "${LIBS[@]}"; do
    TARGET=$(find /usr/lib/aarch64-linux-gnu -name "$lib*" -print -quit)
    if [ -n "$TARGET" ]; then
        echo "Copying $lib..."
        cp -L "$TARGET" "$LIB_DIR/$lib"
    else
        echo "Warning: $lib not found! (Check if package is installed in Docker)"
    fi
done

# 7. 패키징
cd "$OUTPUT_DIR"
BUILD_DATE=$(date +%m%d)
# 기존에 Emu/, lib/, logs/가 깔끔하게 들어오도록 경로 유지
OUT_FILENAME="mkxp-z.aarch64.${BUILD_DATE}.7z"
7z a -t7z -m0=lzma2 -mx=9 "$OUT_FILENAME" Emu/ lib/ logs/

echo "=== Build complete: ${OUTPUT_DIR}/${OUT_FILENAME} ==="
