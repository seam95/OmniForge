import SwiftUI

// MARK: - 取色器详情页
//
// 实用工具 tab 第三项的内容。与 cleaner / uninstaller 一致采用共享 ContentView + 双布局，
// 当前仅 `.compact`（控制中心）实际使用，保留 `.settings` 分支与项目模式一致。
// 取色 UI 由系统 `NSColorSampler` 提供；本视图只负责触发、展示结果、按格式复制。

struct ColorPickerContentView: View {
    let strings: Strings
    let layout: UtilityContentLayout

    @ObservedObject private var service = ColorPickerService.shared
    /// 哪个格式行刚被复制，用于短暂显示「已复制」反馈。
    @State private var copiedFormat: ColorFormat?

    var body: some View {
        Group {
            if service.isPicking {
                pickingState
            } else if let color = service.currentColor {
                resultState(color)
            } else {
                idleState
            }
        }
        .frame(maxWidth: layout.contentWidth ?? .infinity)
        .frame(minHeight: layout == .compact ? 420 : 480)
        .padding(layout.horizontalPadding)
    }

    // MARK: 空状态 — 居中取色按钮

    private var idleState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "eyedropper")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text(strings.colorPickerIntroTitle)
                .font(.system(size: 17, weight: .semibold))
            Text(strings.colorPickerIntroCaption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Button(strings.colorPickerStart) { service.startPicking() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: 取色中 — 按钮置灰

    private var pickingState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "eyedropper")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
            Text(strings.colorPickerInProgress)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: 已取色 — 色块 + 三格式行

    private func resultState(_ color: NSColor) -> some View {
        VStack(spacing: 16) {
            // 大色块预览：圆角矩形填满拾取颜色。
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(height: layout == .compact ? 120 : 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )

            // 三格式行，每行可点击复制当前格式。
            VStack(spacing: 8) {
                ForEach(ColorFormat.allCases, id: \.rawValue) { format in
                    formatRow(format, color: color)
                }
            }

            // 再次取色按钮
            Button(strings.colorPickerPickAgain) { service.startPicking() }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
        }
    }

    /// 单个格式行：标签 + 格式化文本 + 复制反馈。
    @ViewBuilder
    private func formatRow(_ format: ColorFormat, color: NSColor) -> some View {
        let text = format.string(from: color)
        Button {
            service.copy(text)
            showCopiedFeedback(format)
        } label: {
            HStack(spacing: 10) {
                Text(format.localizedLabel(in: strings))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if copiedFormat == format {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(copiedFormat == format ? 0.06 : 0.03))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(format.localizedLabel(in: strings)) \(text)")
    }

    /// 短暂显示「已复制」对勾，1.2 秒后清除。
    private func showCopiedFeedback(_ format: ColorFormat) {
        withAnimation { copiedFormat = format }
        let token = format
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // 仅当仍是同一格式时清除，避免覆盖更新的反馈。
            if copiedFormat == token {
                withAnimation { copiedFormat = nil }
            }
        }
    }
}

// MARK: - ColorFormat 本地化标签

private extension ColorFormat {
    func localizedLabel(in strings: Strings) -> String {
        switch self {
        case .hex: return strings.colorPickerFormatHex
        case .rgb: return strings.colorPickerFormatRGB
        case .hsl: return strings.colorPickerFormatHSL
        }
    }
}
