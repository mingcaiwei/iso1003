#!/bin/bash
# ==========================================================================
#  EthernetLauncher 构建脚本
#  在 macOS 上运行（本地 Mac 或 GitHub Actions 的 macOS runner 均可）
#  产出：EthernetLauncher.tipa
# ==========================================================================
set -e

APP_NAME="EthernetLauncher"
BUNDLE_ID="com.ceshi.ethlauncher"
MIN_IOS="14.0"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/Payload/${APP_NAME}.app"

echo "==> 清理"
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_DIR}"

echo "==> 编译 ${APP_NAME} (arm64)"
xcrun -sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=${MIN_IOS} \
    -fobjc-arc \
    -framework Foundation \
    -framework SystemConfiguration \
    -framework CoreFoundation \
    -O2 \
    -o "${APP_DIR}/${APP_NAME}" \
    "${ROOT_DIR}/main.m"

echo "==> 拷贝资源"
cp "${ROOT_DIR}/Info.plist" "${APP_DIR}/Info.plist"

# 用 ldid 写入 entitlements 并做假签名（保留任意 entitlements，TrollStore 需要）
if command -v ldid >/dev/null 2>&1; then
    echo "==> ldid 假签名 + entitlements"
    ldid -S"${ROOT_DIR}/entitlements.plist" "${APP_DIR}/${APP_NAME}"
else
    echo "==> 未找到 ldid，回退到 codesign 自签"
    codesign --force --sign - \
        --entitlements "${ROOT_DIR}/entitlements.plist" \
        --timestamp=none \
        "${APP_DIR}/${APP_NAME}"
fi

echo "==> 打包 .tipa"
cd "${BUILD_DIR}"
zip -qry "${ROOT_DIR}/${APP_NAME}.tipa" Payload

echo "==> 完成：${ROOT_DIR}/${APP_NAME}.tipa"
ls -lh "${ROOT_DIR}/${APP_NAME}.tipa"
