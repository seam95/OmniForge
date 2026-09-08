import SwiftUI

/// 单个特性的行视图 — 图标 + 名称 + 描述 + 安装/卸载 toggle。
/// 状态变更委托给 FeatureRuntime.setAvailableAsync。
struct FeatureRow: View {
    let feature: AppFeature
    @ObservedObject var runtime: FeatureRuntime
    let strings: Strings
    let uninstallGuard: UtilityUninstallGuard

    private var isAvailable: Bool {
        runtime.isAvailable(feature)
    }

    private var phase: FeatureAvailabilityPhase {
        runtime.phase(for: feature)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: feature.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(isAvailable ? Color.accentColor : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.hubName(in: strings))
                        .font(.body)
                    Text(feature.hubDescription(in: strings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isAvailable },
                    set: { newValue in
                        guard uninstallGuard.canSetAvailability(of: feature, to: newValue) else { return }
                        Task { @MainActor in
                            _ = await runtime.setAvailableAsync(feature, newValue)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(
                    (isAvailable && uninstallGuard.isUninstallBlocked(for: feature))
                        || phase == .installing
                        || phase == .uninstalling
                )
            }

            if let failedMessage = transactionFailedMessage {
                HStack(spacing: 8) {
                    Text(failedMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(strings.featureHubRetryUninstall) {
                        Task { @MainActor in
                            _ = await runtime.setAvailableAsync(feature, retryAvailable)
                        }
                    }
                    .controlSize(.small)
                    .disabled(phase == .uninstalling || phase == .installing)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 安装/卸载失败提示与重试方向由 phase 携带的请求方向决定
    /// （卸载失败时 availability 仍为 true，不能用它判向）。
    private var transactionFailedMessage: String? {
        guard case .failed(let requestedAvailable, let reason) = phase else { return nil }
        let format = requestedAvailable
            ? strings.featureHubInstallFailedFormat
            : strings.featureHubUninstallFailedFormat
        return String(format: format, reason)
    }

    private var retryAvailable: Bool {
        guard case .failed(let requestedAvailable, _) = phase else { return false }
        return requestedAvailable
    }
}
