#!/bin/bash
# =============================================================================
# panvk-mtk-driver 一键构建脚本
#
# 功能: 克隆基础 Mesa 源码 -> 应用补丁 -> 构建离线编译器 -> 构建 Android
#       Vulkan HAL (libvulkan_panfrost.so) -> 产出 vulkan.mali.so
#
# 环境: Ubuntu 22.04/24.04 (WSL2 或原生), 需要 sudo
# 用法: bash build.sh [release|debug]
# =============================================================================
set -euo pipefail

MODE="${1:-release}"

# --- 可配置路径 ------------------------------------------------------------
WORKDIR="${WORKDIR:-$HOME/panvk-mtk}"
MESA_FORK_URL="${MESA_FORK_URL:-https://github.com/funnymdzz/mesa.git}"
MESA_COMMIT="${MESA_COMMIT:-6598829019c}"   # 补丁基于此提交
NDK_VERSION="${NDK_VERSION:-r27c}"
NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
COMPILER_PREFIX="${COMPILER_PREFIX:-$WORKDIR/mesa-compiler}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$SCRIPT_DIR/patches/panvk_mtk.patch"
OUT_DIR="$SCRIPT_DIR/driver"

mkdir -p "$WORKDIR"

# --- 1. 系统依赖 -----------------------------------------------------------
if [ "${SKIP_DEPS:-0}" != "1" ]; then
  echo "==> [1/6] 安装系统依赖"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y || true
    sudo apt-get install -y \
      python3 python3-pip python3-setuptools python3-wheel ninja-build \
      pkg-config git wget unzip curl patchelf \
      clang-18 llvm-18-dev libclang-18-dev libclang-cpp18-dev libclang-rt-18-dev \
      libclc-18-dev libllvmspirvlib-18-dev lld-18 lld \
      spirv-tools glslang-tools libx11-dev libxext-dev libxdamage-dev \
      libxfixes-dev libxrandr-dev libdrm-dev libexpat1-dev zlib1g-dev \
      bison flex gettext xsltproc libwayland-dev \
      python3-mako python3-yaml python3-packaging python3-zstandard || true
  fi

  # 确保 pip 安装最新版 meson (>= 1.7.0 为 Mesa Rust 所需) 及 python 模板依赖
  pip3 install --break-system-packages --upgrade "meson>=1.7.0" mako packaging pyyaml 2>/dev/null || \
    pip3 install --upgrade "meson>=1.7.0" mako packaging pyyaml 2>/dev/null || true

  # 确保 Rust 工具链 (>= 1.85.0 为 Mesa 所需)
  if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  fi
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env" || true
  rustup default stable 2>/dev/null || true
  rustup target add aarch64-linux-android 2>/dev/null || true

  # 确保 bindgen (0.71.1 或 0.72.1 为 Mesa 所需)
  export PATH="$HOME/.cargo/bin:$PATH"
  if ! command -v bindgen >/dev/null 2>&1 || [ "$(bindgen --version 2>/dev/null | awk '{print $2}')" == "0.72.0" ]; then
    echo "==> 安装 bindgen-cli 0.72.1"
    cargo install --locked --version 0.72.1 bindgen-cli
  fi
fi

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env" || true
export PATH="$COMPILER_PREFIX/bin:$HOME/.cargo/bin:/usr/lib/llvm-18/bin:$PATH"
export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig:/usr/lib/llvm-18/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LIBCLANG_PATH=/usr/lib/llvm-18/lib
export CLANG_PATH=/usr/lib/llvm-18/bin/clang
export BINDGEN_EXTRA_CLANG_ARGS="-target aarch64-linux-android --sysroot=$WORKDIR/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

# --- 2. NDK -----------------------------------------------------------------
echo "==> [2/6] 下载/解压 NDK ${NDK_VERSION}"
NDK="$WORKDIR/android-ndk-${NDK_VERSION}"
if [ ! -d "$NDK" ]; then
  wget -q "$NDK_URL" -O "$WORKDIR/ndk.zip"
  unzip -q -o "$WORKDIR/ndk.zip" -d "$WORKDIR"
  rm -f "$WORKDIR/ndk.zip"
fi
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

# --- 3. Mesa 源码 + 补丁 ----------------------------------------------------
echo "==> [3/6] 克隆 Mesa 源码并应用补丁"
if [ ! -d "$WORKDIR/mesa/.git" ]; then
  git clone "$MESA_FORK_URL" "$WORKDIR/mesa"
fi
cd "$WORKDIR/mesa"
git checkout "$MESA_COMMIT" 2>/dev/null || (git fetch origin && git checkout "$MESA_COMMIT")
if ! git apply --check "$PATCH" 2>/dev/null; then
  # 补丁可能已应用, 检查后再决定
  if git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "    补丁已应用, 跳过"
  else
    echo "ERROR: 补丁无法应用 (请确认 MESA_COMMIT=$MESA_COMMIT)"
    exit 1
  fi
else
  git apply "$PATCH"
  echo "    补丁已应用"
fi

# --- 4. 离线编译器 (mesa_clc / panfrost_compile) ----------------------------
echo "==> [4/6] 构建离线编译器"
if [ ! -d "$WORKDIR/mesa/build-compiler" ]; then
  meson setup build-compiler \
    -Dprefix="$COMPILER_PREFIX" \
    -Dbuildtype=release \
    -Dstrip=true \
    -Dplatforms= \
    -Dgallium-drivers= \
    -Dvulkan-drivers= \
    -Dmesa-clc=enabled \
    -Dinstall-mesa-clc=true \
    -Dtools=panfrost \
    -Dprecomp-compiler=enabled \
    -Dinstall-precomp-compiler=true
fi
meson compile -C build-compiler
meson install -C build-compiler
export PATH="$COMPILER_PREFIX/bin:$PATH"

# --- 5. 交叉编译 Android Vulkan HAL -----------------------------------------
echo "==> [5/6] 配置并构建 Android Vulkan HAL ($MODE)"
cat > "$WORKDIR/android-kbase.ini" <<EOF
[constants]
ndk_path = '$NDK'
prebuilt = ndk_path + '/toolchains/llvm/prebuilt/linux-x86_64/bin'

[binaries]
ar      = prebuilt + '/llvm-ar'
c       = prebuilt + '/aarch64-linux-android34-clang'
cpp     = [prebuilt + '/aarch64-linux-android34-clang++',
           '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables',
           '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
strip   = prebuilt + '/llvm-strip'
rust    = ['rustc', '--target', 'aarch64-linux-android']
rust_ld = prebuilt + '/aarch64-linux-android34-clang'
c_ld    = 'lld'
cpp_ld  = 'lld'

[host_machine]
system     = 'android'
cpu_family = 'aarch64'
cpu        = 'armv8'
endian     = 'little'

[properties]
rust_std   = '2021'
EOF

BUILD_DIR="build-kbase-android"
if [ "$MODE" = "debug" ]; then
  BUILD_DIR="build-kbase-android-debug"
fi

if [ ! -d "$BUILD_DIR/meson-private" ]; then
  BTYPE=release
  BNDEBUG=true
  [ "$MODE" = "debug" ] && BTYPE=debug && BNDEBUG=false
  meson setup "$BUILD_DIR" \
    --cross-file "$WORKDIR/android-kbase.ini" \
    --buildtype="$BTYPE" \
    -Db_ndebug="$BNDEBUG" \
    -Dbuild-tests=false \
    -Dplatforms=android \
    -Dplatform-sdk-version=34 \
    -Dandroid-stub=true \
    -Dandroid-libbacktrace=disabled \
    -Degl=disabled \
    -Dgallium-drivers= \
    -Dgbm=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglx=disabled \
    -Dinstall-mesa-clc=false \
    -Dinstall-precomp-compiler=false \
    -Dlibunwind=disabled \
    -Dlmsensors=disabled \
    -Dllvm=disabled \
    -Dmesa-clc=system \
    -Dopengl=false \
    -Dpanfrost-kmds=kbase,panthor \
    -Dpanfrost-rust=true \
    -Dprecomp-compiler=system \
    -Dshared-glapi=disabled \
    -Dtools= \
    -Dvalgrind=disabled \
    -Dvideo-codecs= \
    -Dvulkan-drivers=panfrost \
    -Dvulkan-layers= \
    -Dxmlconfig=disabled \
    -Dzstd=disabled \
    -Dallow-fallback-for=libdrm
fi
meson compile -C "$BUILD_DIR"

# --- 6. 产出 ----------------------------------------------------------------
echo "==> [6/6] 产出 vulkan.mali.so"
SO="$WORKDIR/mesa/$BUILD_DIR/src/panfrost/vulkan/libvulkan_panfrost.so"
mkdir -p "$OUT_DIR"
cp "$SO" "$OUT_DIR/vulkan.mali.so"
if [ "$MODE" = "release" ] && [ -f "$NDK_BIN/llvm-strip" ]; then
  echo "==> 执行 llvm-strip --strip-unneeded"
  "$NDK_BIN/llvm-strip" --strip-unneeded "$OUT_DIR/vulkan.mali.so"
fi
patchelf --set-soname vulkan.mali.so "$OUT_DIR/vulkan.mali.so"
ls -la "$OUT_DIR/vulkan.mali.so"
sha256sum "$OUT_DIR/vulkan.mali.so" | tee "$OUT_DIR/vulkan.mali.so.sha256"
echo
echo "构建完成: $OUT_DIR/vulkan.mali.so"
