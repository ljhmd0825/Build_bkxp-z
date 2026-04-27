#!/bin/bash
set -e

# 0. 경로 및 환경 설정
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
export GIT_TERMINAL_PROMPT=0  # Git 인증 대기 차단

# 환경 설정
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
EMU_DIR="$OUTPUT_DIR/Emu/MKXP-Z"
LIB_DIR="$OUTPUT_DIR/lib"
LOGS_DIR="$OUTPUT_DIR/logs"

mkdir -p "$LOGS_DIR"

echo "=== Preparing mkxp-z with SDL2_sound Subproject ==="

# 1. mkxp-z 소스 체크아웃
if [ ! -d "mkxp-z" ]; then
    git clone --recursive https://github.com/mkxp-z/mkxp-z.git mkxp-z
fi
cd mkxp-z

# 2. [핵심] SDL2_sound를 subprojects에 강제 주입
# 시스템에 없으므로, Meson이 스스로 빌드할 수 있게 소스를 서브프로젝트로 옮깁니다.
if [ ! -d "subprojects/SDL2_sound" ]; then
    echo "--- Fetching SDL2_sound as a subproject ---"
    git clone https://github.com/icculus/SDL2_sound.git subprojects/SDL2_sound
fi

# 3. Meson 크로스 파일 생성 (상위 디렉토리 기준)
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

# 4. Meson 빌드 설정 (수동 옵션 없이 최적화)
# --wrap-mode=forcefallback을 주면, Meson이 방금 넣어둔 subprojects/SDL2_sound를 발견하고
# 알아서 aarch64용으로 같이 빌드해버립니다.
rm -rf build-aarch64
meson setup build-aarch64 \
    --cross-file ../cross_file.meson \
    --buildtype release \
    --prefix="$EMU_DIR" \
    --wrap-mode=forcefallback \
    --strip | tee "$LOGS_DIR/meson_summary.txt"

# 5. 빌드 및 설치
ninja -C build-aarch64
ninja -C build-aarch64 install

# 6. 라이브러리 수집
echo "=== Collecting shared libraries ==="
mkdir -p "$LIB_DIR"
# 빌드된 결과물에서 SDL2_sound도 찾아야 합니다.
cp -P build-aarch64/subprojects/SDL2_sound/libSDL2_sound* "$LIB_DIR/" 2>/dev/null || true

LIBS=("libSDL2-2.0.so.0" "libSDL2_net-2.0.so.0" "libfluidsynth.so.3" "libphysfs.so.1")
for lib in "${LIBS[@]}"; do
    TARGET=$(find /usr/lib/aarch64-linux-gnu -name "$lib*" -print -quit)
    [ -n "$TARGET" ] && cp -L "$TARGET" "$LIB_DIR/$lib"
done

# 7. 패키징
cd "$OUTPUT_DIR"
7z a -t7z -m0=lzma2 -mx=9 "mkxp-z.aarch64.$(date +%m%d).7z" Emu/ lib/ logs/
