#!/bin/bash
set -e

# 0. 경로 설정
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# 환경 설정
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
EMU_DIR="$OUTPUT_DIR/Emu/MKXP-Z"
LIB_DIR="$OUTPUT_DIR/lib"
LOGS_DIR="$OUTPUT_DIR/logs"

mkdir -p "$LOGS_DIR"

echo "=== Building mkxp-z for aarch64 (Subprojects Mode) ==="

# 1. 소스 체크아웃 (이미 있다면 건너뜀)
if [ ! -d "mkxp-z" ]; then
    git clone --recursive https://github.com/mkxp-z/mkxp-z.git mkxp-z
fi

# 1-1. [추가] SDL2_sound 수동 크로스 빌드 (시스템에 없으므로 직접 생성)
if [ ! -d "SDL2_sound" ]; then
    echo "=== Building SDL2_sound for aarch64 ==="
    git clone https://github.com/icculus/SDL2_sound.git
    cd SDL2_sound
    mkdir build-cross && cd build-cross
    
    # CMake를 이용한 크로스 빌드 (우리가 설치한 aarch64 도구 활용)
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
        -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
        -DCMAKE_INSTALL_PREFIX=/usr/lib/aarch64-linux-gnu \
        -DSDLSOUND_BUILD_STATIC=ON \
        -DSDLSOUND_BUILD_SHARED=ON
    
    make -j$(nproc)
    make install  # Docker 내부의 arm64 라이브러리 경로로 강제 설치
    cd ../..
fi

cd mkxp-z

# 2. Meson 크로스 파일 생성 (상위 디렉토리에 생성)
cat <<EOF > ../cross_file.meson
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'

[properties]
pkg_config_libdir = '/usr/lib/aarch64-linux-gnu/pkgconfig'
EOF

# 3. Meson 빌드 설정
# 줄바꿈 에러를 방지하기 위해 배열 형태로 인자를 전달하거나 한 줄로 구성합니다.
rm -rf build-aarch64
meson setup build-aarch64 \
    --cross-file ../cross_file.meson \
    --buildtype release \
    --prefix="$EMU_DIR" \
    --wrap-mode=forcefallback \
    --strip | tee "$LOGS_DIR/meson_summary.txt"

# 4. 빌드 및 설치
ninja -C build-aarch64
ninja -C build-aarch64 install

# 5. 라이브러리 수집
echo "=== Collecting shared libraries ==="
mkdir -p "$LIB_DIR"
# 서브모듈로 빌드할 경우 라이브러리 파일명이 달라질 수 있으니 확인이 필요합니다.
LIBS=("libSDL2-2.0.so.0" "libSDL2_net-2.0.so.0" "libfluidsynth.so.3")

for lib in "${LIBS[@]}"; do
    TARGET=$(find /usr/lib/aarch64-linux-gnu -name "$lib*" -print -quit)
    [ -n "$TARGET" ] && cp -L "$TARGET" "$LIB_DIR/$lib"
done

# 6. 패키징
cd "$OUTPUT_DIR"
7z a -t7z -m0=lzma2 -mx=9 "mkxp-z.aarch64.$(date +%m%d).7z" Emu/ lib/ logs/
