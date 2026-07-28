import SwiftUI

/// 全局恢复横幅模型；不依赖 `.keepAwake` availability。
struct KeepAwakeRecoveryBannerModel: Equatable {
    var isVisible: Bool
    var title: String
    var detail: String
    var showsRetry: Bool
    var retryLabel: String

    static let hidden = KeepAwakeRecoveryBannerModel(
        isVisible: false,
        title: "",
        detail: "",
        showsRetry: false,
        retryLabel: ""
    )

    static func from(
        state: ClamshellRecoveryUIState,
        strings: Strings = .en
    ) -> KeepAwakeRecoveryBannerModel {
        switch state {
        case .idle, .recovered:
            return .hidden
        case .checking:
            return KeepAwakeRecoveryBannerModel(
                isVisible: true,
                title: strings.keepAwakeRecoveryCheckingTitle,
                detail: strings.keepAwakeRecoveryCheckingDetail,
                showsRetry: false,
                retryLabel: strings.keepAwakeRetry
            )
        case .recovering:
            return KeepAwakeRecoveryBannerModel(
                isVisible: true,
                title: strings.keepAwakeRecoveryRestoringTitle,
                detail: strings.keepAwakeRecoveryRestoringDetail,
                showsRetry: false,
                retryLabel: strings.keepAwakeRetry
            )
        case .cleanupRequired(let error):
            return KeepAwakeRecoveryBannerModel(
                isVisible: true,
                title: strings.keepAwakeRecoveryCleanupTitle,
                detail: String(describing: error),
                showsRetry: true,
                retryLabel: strings.keepAwakeRetry
            )
        case .conflict(let reason):
            return KeepAwakeRecoveryBannerModel(
                isVisible: true,
                title: strings.keepAwakeRecoveryConflictTitle,
                detail: reason,
                showsRetry: true,
                retryLabel: strings.keepAwakeRetry
            )
        }
    }
}

struct KeepAwakeRecoveryBanner: View {
    let model: KeepAwakeRecoveryBannerModel
    var onRetry: () -> Void = {}

    var body: some View {
        if model.isVisible {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
                if model.showsRetry {
                    Button(model.retryLabel, action: onRetry)
                        .buttonStyle(.bordered)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}
