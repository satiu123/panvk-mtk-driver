# panvk-mtk-driver — MTK Mali Vulkan 驱动(panvk kbase 后端)

为 **Redmi Note 11T Pro / xaga(天玑 8100, Mali-G610 MC6, Android 15 / HyperOS)** 构建的
**panvk(Mesa Vulkan)kbase 后端** 系统 Vulkan 驱动,替代原厂 `vulkan.mali.so`,驱动 Vulkan HWUI(`debug.hwui.renderer=skiavk`)正常工作。

## 背景

- 设备:kernel 5.10.237,kbase **r32p1 / UK 1.18(CSF uAPI 1.18)**,`/dev/mali0`
- 源码:基于 `funnymdzz/mesa` 的 KRAID fork(panvk kbase 后端)
- 目标:让系统 Vulkan 渲染(包括 HWUI/Skia Vulkan)在 MTK gralloc 显示管线中正常出画面

## 关键问题与修复(`patches/panvk_mtk.patch`)

### 1. MTK gralloc 报告 `DRM_FORMAT_MOD_INVALID`,但实际分配 ARM AFBC(32x8|SPARSE|SPLIT|YTR)

- `src/vulkan/runtime/vk_android.c` / `src/panfrost/vulkan/panvk_image.c`:
  INVALID modifier 回退到 **MTK 实际 AFBC modifier**(`0x0800000000000072`)而不是 LINEAR。
- `src/panfrost/lib/pan_mod.c` / `src/panfrost/lib/pan_desc.c`:
  **AFBC body 4096 对齐**(`get_afbc_att_mem_props` 与 `pan_mod_afbc_init_slice_layout` 保持一致),
  GPU 把 payload 写到显示管线期望的位置。这是"白屏"的根因。

### 2. SurfaceFlinger RenderEngine 崩溃(DEVICE_LOST)

- `src/vulkan/runtime/vk_android.c`:`copy_sync_payloads` 在 kbase 后端置 `NULL`
  (DRM syncobj 路径会在 `to_drm_syncobj` 断言崩溃),改用 `QueueSubmit2` 回退。
- `src/vulkan/runtime/vk_queue.c` / `vk_device.c`:增加设备丢失诊断日志。

### 3. GPU 作业超时挂起(kick 竞态)

- `src/panfrost/vulkan/csf/panvk_vX_gpu_queue.c`:
  `kbase_subqueue_publish` 去掉 userspace doorbell 快速路径,**总是 kick 调度器**
  (doorbell 会在 active→idle 切换时丢作业,导致 GPU 空闲但队列有未执行作业 → 10s 超时 → DEVICE_LOST)。
- 超时从 10s 放宽到 120s(`KBASE_WAIT_TIMEOUT_NS`)。

### 4. 其他

- `src/panfrost/vulkan/panvk_drm_stub.c`(新文件):`drmCloseBufferHandle` 符号 stub(设备 libdrm 缺失)。
- `src/panfrost/lib/kmod/kbase_kmod.c`:`MEM_ALLOC_EX` ENOTTY 回退 `MEM_ALLOC`;队列优先级加入 HIGH|REALTIME。
- `src/panfrost/vulkan/panvk_vX_physical_device.c`:feature 表全量声称 v1.0 支持。
- `src/panfrost/vulkan/panvk_vX_shader.c`:默认 shader stage 忽略而非断言。
- `src/vulkan/runtime/vk_android.c`:`vk_android_find_dmabuf_fd` 选最大 size 的 dma-buf fd(MTK gralloc 3 fd)。
- `src/panfrost/lib/kmod/pan_kmod.c`:dmabuf size 用 fstat 兜底(lseek ESPIPE)。
- `src/vulkan/util/vk_physical_device_features_gen.py`:feature 校验加日志。

## 构建

环境: GitHub Actions (Ubuntu 24.04 runner), 或 WSL2 / 原生 Ubuntu 24.04 (NDK r27c)。

### 0. GitHub Actions 自动编译 (推荐，免本地配置)

本项目已配置完整的 GitHub Actions CI 工作流(`.github/workflows/build.yml`):
- **触发方式**:
  - 推送代码到 `main` 分支或创建版本标签(如 `v1.0`)时自动触发构建。
  - 在 GitHub 仓库页面的 **Actions** 选项卡 -> **Build PanVK MTK Driver** -> **Run workflow** 手动触发，支持选择 `release` / `debug` 模式，以及是否自动创建 GitHub Release。
- **产物与交付物**:
  - `vulkan.mali.so` 与 SHA256 校验和。
  - `Magisk-PanVK-MTK-<MODE>.zip`: 支持直接在 **KernelSU / Magisk / APatch** 管理器中刷入的模块包(自动无损 systemless 覆盖驱动并注入 `system.prop` 参数，免去手动 remount 根分区风险)。
  - `panvk-mtk-driver-standalone-<MODE>.zip`: 独立安装包，附带 Windows (`install.bat`) 和 Linux/macOS (`install.sh`) 的一键 ADB 部署脚本。

### 1. 本地一键构建

仓库根目录的 `build.sh` 自动完成:安装依赖 → 下载 NDK → 克隆基础 Mesa 源码
(funnymdzz/mesa @ `6598829019c`) → 应用补丁 → 构建离线编译器 → 交叉编译
Android Vulkan HAL → 产出 `driver/vulkan.mali.so`。

```bash
bash build.sh            # release (默认)
bash build.sh debug      # debug (带日志)
```

产物在 `driver/vulkan.mali.so`。

### 手动构建

```bash
# 1. 系统依赖
sudo apt install -y meson ninja-build python3-pip clang llvm-18-dev \
  libclang-18-dev spirv-tools glslang-tools rustc cargo libdrm-dev
rustup target add aarch64-linux-android

# 2. NDK r27c
wget https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
unzip android-ndk-r27c-linux.zip

# 3. Mesa 源码 + 补丁
git clone https://github.com/funnymdzz/mesa.git ~/mesa
cd ~/mesa && git checkout 6598829019c
git apply <repo>/patches/panvk_mtk.patch

# 4. 离线编译器
meson setup build-compiler -Dprefix=$HOME/mesa-compiler -Dbuildtype=release \
  -Dplatforms= -Dgallium-drivers= -Dvulkan-drivers= -Dmesa-clc=enabled \
  -Dinstall-mesa-clc=true -Dtools=panfrost -Dprecomp-compiler=enabled \
  -Dinstall-precomp-compiler=true
meson install -C build-compiler

# 5. Android HAL(参照 build.sh 中的 meson setup 参数)
meson setup build-kbase-android --cross-file <android-kbase.ini> ... 
meson compile -C build-kbase-android
```

## 部署

```bash
adb push vulkan.mali.so /data/local/tmp/
adb shell "su -c 'mount -o remount,rw /vendor && \
  cp /data/local/tmp/vulkan.mali.so /vendor/lib64/hw/mt6895/vulkan.mali.so && \
  chmod 644 /vendor/lib64/hw/mt6895/vulkan.mali.so'"
adb reboot
```

注意:`/vendor` 可能是 erofs/ext4,必须在同一个 `su` 会话内 remount + cp。
原厂驱动先备份(参见原项目脚本)。回滚:把备份的 `vulkan.mali.so` 拷回去。

## 启用 Vulkan HWUI

KernelSU 模块 `hwui_use_vulkan`(system.prop,见 `config/system.prop`):

```
debug.hwui.renderer=skiavk
debug.renderengine.backend=skiagl    # SF 合成用 GL(Mali blob 原生解码 AFBC)
debug.renderengine.vulkan=false
debug.mesa.log.level=debug
debug.mesa.vk.log=1
# kbase DVFS 保持 MTK 默认
debug.mesa.panvk.kbase.dvfs=none
```

关键:SF RenderEngine 用 **GL(skiagl)** 读 AFBC 层缓冲(Mali blob 原生支持),
HWUI 用 **Vulkan(skiavk)** 渲染 —— 二者配合避免 panvk 合成崩溃。

## GPU 调速器(DVFS)

本机 GPU 默认使用 **MTK 私有 DVFS**(`mtk_gpufreq_mt6895` + SSPM/GPUEB + GED
frame-based DVFS),非标准 cpufreq governor。

驱动支持 `debug.mesa.panvk.kbase.dvfs`(= 环境变量 `PANVK_KBASE_DVFS`)控制:

| 值 | 行为 |
|---|---|
| `none`(默认) | 不动,保持 MTK 出厂 DVFS |
| `auto` | kbase `quickstep_use_mcu`(不可用则 `capacity_use_mcu`),范围 min-max |
| `default` | kbase `quickstep` |
| `max` | 锁定最高频率 |
| `<kHz>` | 锁定指定频率 |

写路径:`/sys/class/misc/mali0/device/governor`。

> 若出现 GPU 作业超时挂起(SSPM DVFS 频率切换竞态),可尝试 `max` 锁定最高频率。

## 交付物

- `patches/panvk_mtk.patch` — 全部源码修改
- `build-scripts/` — 构建脚本
- `driver/vulkan.mali.so` — 编译产物(release)
- 验证工具(设备端 `/data/local/tmp/`):vktest / vkcompute / vkgfx2/3/4(渲染+导入验证)

## 限制 / 已知问题

- 深度负载下偶发 GPU 作业挂起 → DEVICE_LOST → 应用/系统软重启(已通过 always-kick 缓解)。
- kbase `MEM_ALLOC_EX` 等 ioctl 内核不支持(走 legacy 回退)。
- 如需完全稳定,可退回 `debug.hwui.renderer=skiagl`(GL 路径无崩溃)。

## 许可证

基于 Mesa 3D(MIT 派生)。补丁仅为本项目用途,遵守上游许可证。
