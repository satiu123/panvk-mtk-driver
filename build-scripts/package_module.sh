#!/bin/bash
set -euo pipefail

MODE="${1:-release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER_SO="$SCRIPT_DIR/driver/vulkan.mali.so"
DRIVER_DIR="$SCRIPT_DIR/driver"
CONFIG_PROP="$SCRIPT_DIR/config/system.prop"

if [ ! -f "$DRIVER_SO" ]; then
  echo "ERROR: Driver not found at $DRIVER_SO"
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/panvk_pkg.XXXXXX)"
trap "rm -rf "$TMP_DIR"" EXIT

echo "==> 打包 Magisk / KernelSU 刷机模块"
MAGISK_ROOT="$TMP_DIR/magisk"
mkdir -p "$MAGISK_ROOT/system/vendor/lib64/hw/mt6895"
mkdir -p "$MAGISK_ROOT/META-INF/com/google/android"

cat > "$MAGISK_ROOT/module.prop" <<EOF
id=panvk_mtk_driver
name=PanVK MTK Driver (Mali-G610)
version=v1.0-${MODE}
versionCode=100
author=panvk-mtk
description=PanVK (Mesa Vulkan kbase backend) system Vulkan driver replacement for Dimensity 8100 / Mali-G610 (Redmi Note 11T Pro / xaga).
EOF

if [ -f "$CONFIG_PROP" ]; then
  cp "$CONFIG_PROP" "$MAGISK_ROOT/system.prop"
fi

cp "$DRIVER_SO" "$MAGISK_ROOT/system/vendor/lib64/hw/mt6895/vulkan.mali.so"
cp "$DRIVER_SO" "$MAGISK_ROOT/system/vendor/lib64/hw/vulkan.mali.so"

cat > "$MAGISK_ROOT/META-INF/com/google/android/updater-script" <<EOF
#MAGISK
EOF

cat > "$MAGISK_ROOT/META-INF/com/google/android/update-binary" <<EOF
#!/sbin/sh
#################
# Magisk Module #
#################
umask 022
EOF
chmod +x "$MAGISK_ROOT/META-INF/com/google/android/update-binary"

MAGISK_ZIP="$DRIVER_DIR/Magisk-PanVK-MTK-${MODE}.zip"
rm -f "$MAGISK_ZIP"
if command -v zip >/dev/null 2>&1; then
  (cd "$MAGISK_ROOT" && zip -r -q -9 "$MAGISK_ZIP" .)
else
  python3 -c "import shutil, sys; shutil.make_archive(sys.argv[1], 'zip', sys.argv[2])" "${MAGISK_ZIP%.zip}" "$MAGISK_ROOT"
fi
echo "    生成: $MAGISK_ZIP"
(cd "$DRIVER_DIR" && sha256sum "$(basename "$MAGISK_ZIP")" > "$(basename "$MAGISK_ZIP").sha256")

echo "==> 打包 ADB 独立安装包 (Standalone)"
STANDALONE_ROOT="$TMP_DIR/standalone"
mkdir -p "$STANDALONE_ROOT"

cp "$DRIVER_SO" "$STANDALONE_ROOT/vulkan.mali.so"
[ -f "$DRIVER_DIR/vulkan.mali.so.sha256" ] && cp "$DRIVER_DIR/vulkan.mali.so.sha256" "$STANDALONE_ROOT/"
[ -f "$CONFIG_PROP" ] && cp "$CONFIG_PROP" "$STANDALONE_ROOT/"
[ -f "$SCRIPT_DIR/README.md" ] && cp "$SCRIPT_DIR/README.md" "$STANDALONE_ROOT/"

cat > "$STANDALONE_ROOT/install.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "=========================================="
echo " PanVK MTK Driver Installer via ADB"
echo "=========================================="

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: adb command not found. Please install adb and add to PATH."
  exit 1
fi

echo "--> Checking connected ADB devices..."
adb devices

echo "--> Pushing vulkan.mali.so to /data/local/tmp/..."
adb push vulkan.mali.so /data/local/tmp/vulkan.mali.so

echo "--> Installing driver to /vendor/lib64/hw/mt6895/ (with backup)..."
adb shell "su -c '
  mount -o remount,rw /vendor 2>/dev/null || mount -o remount,rw / 2>/dev/null || true
  if [ -f /vendor/lib64/hw/mt6895/vulkan.mali.so ] && [ ! -f /vendor/lib64/hw/mt6895/vulkan.mali.so.bak ]; then
    echo "Backing up original stock driver to vulkan.mali.so.bak..."
    cp /vendor/lib64/hw/mt6895/vulkan.mali.so /vendor/lib64/hw/mt6895/vulkan.mali.so.bak
  fi
  cp /data/local/tmp/vulkan.mali.so /vendor/lib64/hw/mt6895/vulkan.mali.so
  chmod 644 /vendor/lib64/hw/mt6895/vulkan.mali.so
  chown root:root /vendor/lib64/hw/mt6895/vulkan.mali.so
  chcon u:object_r:same_process_hal_file:s0 /vendor/lib64/hw/mt6895/vulkan.mali.so 2>/dev/null || true
  rm -f /data/local/tmp/vulkan.mali.so
  echo "Driver successfully copied!"
'"

echo "=========================================="
echo "Installation complete!"
echo "Reboot device to apply: adb reboot"
echo "=========================================="
EOF
chmod +x "$STANDALONE_ROOT/install.sh"

cat > "$STANDALONE_ROOT/install.bat" <<EOF
@echo off
chcp 65001 >nul
echo ==========================================
echo  PanVK MTK Driver Installer via ADB
echo ==========================================

where adb >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] adb command not found. Please add adb to your PATH.
    pause
    exit /b 1
)

echo [1/3] Pushing vulkan.mali.so to /data/local/tmp/...
adb push vulkan.mali.so /data/local/tmp/vulkan.mali.so
if %errorlevel% neq 0 (
    echo [ERROR] Failed to push driver via adb.
    pause
    exit /b 1
)

echo [2/3] Remounting /vendor and installing to /vendor/lib64/hw/mt6895/...
adb shell "su -c 'mount -o remount,rw /vendor 2>/dev/null; if [ -f /vendor/lib64/hw/mt6895/vulkan.mali.so ] && [ ! -f /vendor/lib64/hw/mt6895/vulkan.mali.so.bak ]; then cp /vendor/lib64/hw/mt6895/vulkan.mali.so /vendor/lib64/hw/mt6895/vulkan.mali.so.bak; fi; cp /data/local/tmp/vulkan.mali.so /vendor/lib64/hw/mt6895/vulkan.mali.so; chmod 644 /vendor/lib64/hw/mt6895/vulkan.mali.so; chown root:root /vendor/lib64/hw/mt6895/vulkan.mali.so; chcon u:object_r:same_process_hal_file:s0 /vendor/lib64/hw/mt6895/vulkan.mali.so 2>/dev/null; rm -f /data/local/tmp/vulkan.mali.so; echo Driver installed successfully.'"

echo [3/3] Done! You can reboot your device now:
echo adb reboot
echo ==========================================
pause
EOF

STANDALONE_ZIP="$DRIVER_DIR/panvk-mtk-driver-standalone-${MODE}.zip"
rm -f "$STANDALONE_ZIP"
if command -v zip >/dev/null 2>&1; then
  (cd "$STANDALONE_ROOT" && zip -r -q -9 "$STANDALONE_ZIP" .)
else
  python3 -c "import shutil, sys; shutil.make_archive(sys.argv[1], 'zip', sys.argv[2])" "${STANDALONE_ZIP%.zip}" "$STANDALONE_ROOT"
fi
echo "    生成: $STANDALONE_ZIP"
(cd "$DRIVER_DIR" && sha256sum "$(basename "$STANDALONE_ZIP")" > "$(basename "$STANDALONE_ZIP").sha256")

echo "打包完成!"
