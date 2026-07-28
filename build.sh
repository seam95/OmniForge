#!/bin/zsh
# OmniForge 构建脚本：SPM 编译 + 手动组装 .app bundle + codesign
# 对标 vorssaint-utils 的 build.sh 模式
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OmniForge"
EXECUTABLE="OmniForge"
BUNDLE_ID="app.omniforge"
ENTITLEMENTS="Resources/OmniForge.entitlements"

# 命令行参数
INSTALL=0
TEST=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
    esac
done

resolve_signing_identity() {
    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true)"
    if [[ -n "$identity" ]]; then
        echo "$identity"
        return
    fi

    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Apple Development' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# --test: 运行 SPM 单元测试
if (( TEST )); then
    echo "▸ Running unit tests…"
    swift test
    exit $?
fi

# 安装版必须保持稳定的代码签名身份，否则 macOS 已授予的隐私权限会绑定到旧身份并失效。
SIGNING_IDENTITY="$(resolve_signing_identity)"
if (( INSTALL )) && [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "✗ --install 需要 Developer ID Application 或 Apple Development 签名身份" >&2
    exit 1
fi

# Step 1: SPM 编译
echo "▸ Building with SPM (release)…"
swift build -c release

BUILD_DIR=".build/release"

# Step 2: 组装 .app bundle（在临时目录中，避免 xattr 污染）
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

# 复制可执行文件
cp "$BUILD_DIR/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"

# 复制 Info.plist
cp Resources/Info.plist "$STAGE/Contents/Info.plist"

# PkgInfo
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Step 3: 编译 Assets.xcassets（生成 Asset.car + AppIcon.icns）
echo "▸ Compiling asset catalog…"
ACTOOL_OUTPUT="$STAGE_PARENT/actool-output"
ASSET_INFO_PLIST="$STAGE_PARENT/asset-info.plist"
if ! xcrun actool --compile "$STAGE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO_PLIST" \
    Resources/Assets.xcassets 2>"$ACTOOL_OUTPUT"; then
    echo "⚠ actool 警告/失败输出:"
    cat "$ACTOOL_OUTPUT" 2>/dev/null || true
fi

# 合并 actool partial Info.plist（CFBundleIconFile / CFBundleIconName）
if [[ -f "$ASSET_INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Merge $ASSET_INFO_PLIST" "$STAGE/Contents/Info.plist" 2>/dev/null \
        || true
    # 兜底：确保图标键存在（Merge 在 key 已存在时不会覆盖，源 plist 已声明时同样生效）
    if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$STAGE/Contents/Info.plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$STAGE/Contents/Info.plist"
    fi
    if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$STAGE/Contents/Info.plist" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$STAGE/Contents/Info.plist"
    fi
fi

# Step 4: 复制本地化资源（若存在）
if [[ -d Resources/en.lproj ]]; then
    cp -R Resources/en.lproj "$STAGE/Contents/Resources/"
fi
if [[ -d Resources/zh-Hans.lproj ]]; then
    cp -R Resources/zh-Hans.lproj "$STAGE/Contents/Resources/"
fi

# Step 5: 清除扩展属性（xattr 会导致 codesign 失败）
xattr -c -r "$STAGE" 2>/dev/null || true

# Step 6: 签名（优先 Developer ID，其次 Apple Development；仅 stage 可 ad-hoc）
if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "▸ Signing with stable identity (hardened runtime): $SIGNING_IDENTITY"
    codesign --force --strip-disallowed-xattrs --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$STAGE"
else
    echo "⚠ 未找到稳定签名身份，仅为 stage 执行 ad-hoc 签名；重新签名后系统权限可能失效" >&2
    codesign --force --strip-disallowed-xattrs \
        --entitlements "$ENTITLEMENTS" --sign - "$STAGE"
fi

codesign --verify --deep --strict "$STAGE"

# Step 7: 复制到 build/stage/
mkdir -p build/stage
rm -rf "build/stage/$APP_NAME.app"
ditto --noextattr --noqtn "$STAGE" "build/stage/$APP_NAME.app"

echo "✓ Bundle ready: build/stage/$APP_NAME.app"

# Step 8: 安装到 /Applications
if (( INSTALL )); then
    echo "▸ Installing to /Applications…"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    ditto --noextattr --noqtn "$STAGE" "/Applications/$APP_NAME.app"
    echo "✓ Installed: /Applications/$APP_NAME.app"
fi

# 清理临时目录
rm -rf "$STAGE_PARENT"
