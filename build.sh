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
# -Osize 替代默认 -O：-O 下 SwiftUI ViewBuilder 闭包被 WMO 内联展开成巨型函数
#（__text 56.5MB，其中 44MB 来自 156 个 >16KB 函数），-Osize 抑制内联后 __text 降至
# 16.7MB，DMG 实测 34.6MB→15.7MB，且全量编译由 8-12 分钟缩短到约 3.5 分钟。
echo "▸ Building with SPM (release, -Osize)…"
swift build -c release -Xswiftc -Osize

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

# Step 4c: 嵌入 Sparkle.framework（自动更新）。
# SPM 对可执行文件只注入 @loader_path 一个 rpath；.app 内 framework 位于
# Contents/Frameworks，必须额外补 @loader_path/../Frameworks，否则 dyld 找不到。
# ditto 原样拷贝以保留 framework 内的符号链接（Versions/Current、Autoupdate、
# Updater.app、XPCServices 均为符号链接；跟随链接展开会破坏后续重签与加载）。
SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    mkdir -p "$STAGE/Contents/Frameworks"
    ditto "$SPARKLE_FRAMEWORK" "$STAGE/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$STAGE/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
else
    echo "⚠ 未找到 Sparkle.framework（请先 swift build 拉取 SPM 产物），将不含自动更新" >&2
fi

# Step 4d: 组装 FinderSync 扩展（OmniForgeFinderSync.appex）
FINDER_EXT_NAME="OmniForgeFinderSync"
FINDER_EXT_EXECUTABLE="$BUILD_DIR/$FINDER_EXT_NAME"
FINDER_EXT_STAGE="$STAGE/Contents/PlugIns/$FINDER_EXT_NAME.appex"
FINDER_ENTITLEMENTS="Sources/OmniForgeFinderSync/Resources/OmniForgeFinderSync.entitlements"
if [[ -f "$FINDER_EXT_EXECUTABLE" ]]; then
    echo "▸ Embedding Finder Sync Extension ($FINDER_EXT_NAME.appex)…"
    mkdir -p "$FINDER_EXT_STAGE/Contents/MacOS" "$FINDER_EXT_STAGE/Contents/Resources"
    cp "$FINDER_EXT_EXECUTABLE" "$FINDER_EXT_STAGE/Contents/MacOS/$FINDER_EXT_NAME"
    cp Sources/OmniForgeFinderSync/Resources/Info.plist "$FINDER_EXT_STAGE/Contents/Info.plist"
    printf 'BNDL????' > "$FINDER_EXT_STAGE/Contents/PkgInfo"

    # appex 与宿主不共享 bundle，需自带 App 图标，否则右键菜单只能用系统通用图标。
    # 取 64px 源（@1x 4.5 倍/@3x 1.5 倍余量，各密度都清晰），拷为 appicon_menu.png；
    # 只拷这一个文件，不复制整个 xcassets，避免资产重复维护。
    APPICON_SRC="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-64.png"
    if [[ -f "$APPICON_SRC" ]]; then
        cp "$APPICON_SRC" "$FINDER_EXT_STAGE/Contents/Resources/appicon_menu.png"
    else
        echo "⚠ 未找到 AppIcon 资源，扩展菜单将退回 SF Symbol 图标" >&2
    fi
fi

# Step 5: 清除扩展属性（xattr 会导致 codesign 失败）
xattr -c -r "$STAGE" 2>/dev/null || true

# Step 6: 签名（优先 Developer ID，其次 Apple Development；仅 stage 可 ad-hoc）
# 嵌入 Sparkle 与 FinderSync 扩展后必须先按顺序重签其嵌套代码再签外层 .app：Hardened Runtime 的
# Library Validation 要求嵌套代码与宿主 Team ID 一致。顺序由内向外，切勿用 --deep（会破坏嵌套签名）。
SPARKLE_EMBEDDED="$STAGE/Contents/Frameworks/Sparkle.framework"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "▸ Signing with stable identity (hardened runtime): $SIGNING_IDENTITY"
    if [[ -d "$SPARKLE_EMBEDDED" ]]; then
        for nested in \
            "$SPARKLE_EMBEDDED/Versions/B/XPCServices/Installer.xpc" \
            "$SPARKLE_EMBEDDED/Versions/B/XPCServices/Downloader.xpc" \
            "$SPARKLE_EMBEDDED/Versions/B/Autoupdate" \
            "$SPARKLE_EMBEDDED/Versions/B/Updater.app"; do
            if [[ -e "$nested" ]]; then
                codesign --force --options runtime --timestamp \
                    --sign "$SIGNING_IDENTITY" "$nested"
            fi
        done
        codesign --force --options runtime --timestamp \
            --sign "$SIGNING_IDENTITY" "$SPARKLE_EMBEDDED"
    fi
    if [[ -d "$FINDER_EXT_STAGE" ]]; then
        codesign --force --options runtime --timestamp \
            --entitlements "$FINDER_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$FINDER_EXT_STAGE"
    fi
    codesign --force --strip-disallowed-xattrs --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$STAGE"
else
    echo "⚠ 未找到稳定签名身份，仅为 stage 执行 ad-hoc 签名；重新签名后系统权限可能失效" >&2
    if [[ -d "$FINDER_EXT_STAGE" ]]; then
        codesign --force --strip-disallowed-xattrs \
            --entitlements "$FINDER_ENTITLEMENTS" --sign - "$FINDER_EXT_STAGE"
    fi
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
    # 必须连 FinderSync 扩展一起杀：appex 进程名是 OmniForgeFinderSync，pkill -x "$EXECUTABLE"
    # 精确匹配杀不到它。旧 appex 会带着内存里的旧代码继续活着，而磁盘上的二进制已被替换，
    # 访达（若未重启）仍连着旧进程 —— 表现为「改了代码却不生效」。
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    pkill -x "$FINDER_EXT_NAME" 2>/dev/null || true
    # 扩展宿主 pkd 也缓存已加载扩展，一并重启以确保重新加载新签名的 appex
    pkill -x pkd 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    ditto --noextattr --noqtn "$STAGE" "/Applications/$APP_NAME.app"
    echo "✓ Installed: /Applications/$APP_NAME.app"
    # 注册或更新 FinderSync 插件
    pluginkit -e use -i app.omniforge.FinderSync 2>/dev/null || true
    # 访达进程内缓存已加载的扩展；替换/重签名 appex 后必须重启访达才会重新加载
    killall Finder 2>/dev/null || true
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
        # 写入图标视图：窗口 600×428（内容区 600×400，背景图 1:1 铺设不缩放）、128pt 图标。
        # 布局契约与 tools/make_dmg_background.swift 成对维护：背景虚线槽心 (150,170)/(450,170)，
        # 图标 position 以「图标渲染中心 = 槽心 + 标题栏 28pt」标定（中心 ≈ position + (2, 29)）。
        # Finder 就绪前写入会静默丢背景/图标尺寸，关键步骤间用 delay 兜底；
        # 首次运行会请求一次「控制 Finder」授权；失败不阻塞出包，仅回退默认外观。
        if ! osascript <<AS 2>/dev/null
tell application "Finder"
    tell disk "$APP_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {180, 120, 780, 548}
        delay 0.5
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to (POSIX file "$MOUNT_DIR/.background/background.png")
        delay 0.5
        set position of item "$APP_NAME.app" of container window to {148, 169}
        set position of item "Applications" of container window to {448, 169}
        delay 0.5
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
