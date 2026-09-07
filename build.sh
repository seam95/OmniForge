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
DMG=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --dmg)     DMG=1 ;;
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
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchServices" "$STAGE/Contents/Library/LaunchDaemons"

# 复制可执行文件
cp "$BUILD_DIR/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"

# 特权风扇 Helper：二进制进 LaunchServices，SMAppService 读取的 plist 进 LaunchDaemons
FAN_HELPER_BUNDLE_PATH="app.omniforge.fan-helper"
cp "$BUILD_DIR/FanControlHelper" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_BUNDLE_PATH"
cp Resources/FanHelperLaunchDaemon.plist "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_BUNDLE_PATH.plist"

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
# 顺序：先签 Helper 二进制（bundle 内嵌可执行文件），再签 app 外层——
# 外层签名会为内嵌内容建立完整性封条，反序会让 Helper 签名失效。
if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "▸ Signing fan helper with stable identity: $SIGNING_IDENTITY"
    codesign --force --strip-disallowed-xattrs --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_BUNDLE_PATH"
    echo "▸ Signing with stable identity (hardened runtime): $SIGNING_IDENTITY"
    codesign --force --strip-disallowed-xattrs --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$STAGE"
else
    echo "⚠ 未找到稳定签名身份，仅为 stage 执行 ad-hoc 签名；重新签名后系统权限可能失效" >&2
    echo "⚠ ad-hoc 签名下 SMAppService 注册风扇 Helper 大概率失败（身份漂移被 launchd 拒绝）" >&2
    codesign --force --strip-disallowed-xattrs \
        --sign - "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_BUNDLE_PATH"
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

# Step 9: 打包 .dmg（用于分发；含拖拽安装布局；包未公证，用户首次打开需 xattr -dr）
if (( DMG )); then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    DMG_NAME="$APP_NAME-$VERSION-macOS.dmg"
    DMG_PATH="build/stage/$DMG_NAME"
    echo "▸ Creating $DMG_NAME …"
    rm -f "$DMG_PATH"

    # 组装卷内容：app + Applications 符号链接（拖拽安装入口）+ 背景图 + 卷图标
    DMG_ROOT="$STAGE_PARENT/dmg"
    mkdir -p "$DMG_ROOT/.background"
    ditto --noextattr --noqtn "build/stage/$APP_NAME.app" "$DMG_ROOT/$APP_NAME.app"
    ln -s /Applications "$DMG_ROOT/Applications"
    cp Resources/dmg/background.png "$DMG_ROOT/.background/background.png"
    cp Resources/dmg/background@2x.png "$DMG_ROOT/.background/background@2x.png"
    if [[ -f "$DMG_ROOT/$APP_NAME.app/Contents/Resources/AppIcon.icns" ]]; then
        cp "$DMG_ROOT/$APP_NAME.app/Contents/Resources/AppIcon.icns" "$DMG_ROOT/.VolumeIcon.icns"
    fi

    # 先产出可读写镜像，写入 Finder 视图（背景/图标布局）后再压缩为 UDZO；app 已签名，ditto 复制不改其内容
    UDRW_PATH="$STAGE_PARENT/dmg-udrw.dmg"
    hdiutil create -volname "$APP_NAME" \
        -fs HFS+ \
        -srcfolder "$DMG_ROOT" \
        -ov -format UDRW \
        "$UDRW_PATH" >/dev/null

    # Finder 仅对默认挂载点（/Volumes/<卷名>）写入 .DS_Store，自定义 -mountpoint 会丢布局
    MOUNT_DIR="/Volumes/$APP_NAME"
    # 残留同名卷会抢占默认挂载点（新卷会挂成「名字 1」导致路径错位），先强制弹出
    if [[ -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    if hdiutil attach -readwrite -noverify -noautoopen "$UDRW_PATH" >/dev/null 2>&1; then
        sleep 2
        # 写入图标视图：600×400 无栏窗口、128pt 图标、背景图、app 与 Applications 对齐箭头两端。
        # 首次运行会请求一次「控制 Finder」授权；失败不阻塞出包，仅回退默认外观。
        if ! osascript <<AS 2>/dev/null
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {180, 120, 780, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to (POSIX file "$MOUNT_DIR/.background/background.png")
        set position of item "$APP_NAME.app" of container window to {86, 126}
        set position of item "Applications" of container window to {386, 126}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
AS
        then
            echo "⚠ Finder 布局写入失败（可能未授权「控制 Finder」），dmg 将使用默认外观" >&2
        fi
        # 卷图标生效需要 custom-icon 标记；SetFile 随 CLT 提供，缺失则跳过
        if command -v SetFile >/dev/null 2>&1 && [[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]]; then
            SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
            SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
        fi
        # 等待 .DS_Store 落盘；Finder 短暂占用卷时延迟重试，最后才强制卸载
        sync
        if ! hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
            sleep 2
            if ! hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
                hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 \
                    || echo "⚠ 卸载 $MOUNT_DIR 失败，卷可能残留，请手动弹出后再打包" >&2
            fi
        fi
    else
        echo "⚠ 无法挂载可读写镜像，跳过 Finder 布局" >&2
    fi

    hdiutil convert "$UDRW_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
    echo "✓ DMG ready: $DMG_PATH"
fi

# 清理临时目录
rm -rf "$STAGE_PARENT"
