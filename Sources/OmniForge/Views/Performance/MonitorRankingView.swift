import SwiftUI
import AppKit

/// Full-page process ranking for a single metric kind (loading / empty / failed / loaded).
struct MonitorRankingView: View {
    let kind: ProcessMetricKind
    let state: ProcessBreakdownState
    let strings: Strings
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    var showsSettingsAction = true
    let onRefresh: () -> Void

    /// Ranking list display limit（与采样侧 `ProcessRankingDisplay.limit` 一致）。
    private static let displayLimit = ProcessRankingDisplay.limit

    /// 当前处于"待终止"确认态的进程 pid；nil 表示无。同时只允许一个进程 armed。
    @State private var armedPID: pid_t?
    /// armed 后自动复位的时长（再次点击确认的窗口期）。
    private static let armResetInterval: Duration = .seconds(3)
    /// 本应用自身 pid，用于排除误杀自己。
    private static var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            footer
        }
        .padding(12)
        // 高度由 MonitorContainerView 固定外壳决定（避免 loading/loaded 之间跳变）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // armed 态超过窗口期未确认则自动复位，避免误留可终止状态。
        .task(id: armedPID) {
            guard armedPID != nil else { return }
            try? await Task.sleep(for: Self.armResetInterval)
            armedPID = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            IconButton(systemImage: "arrow.clockwise", help: strings.monitorRefreshAll) {
                onRefresh()
            }
        }
    }

    private var title: String {
        switch kind {
        case .cpu: return strings.monitorRankingTitleCPU
        case .gpu: return strings.monitorRankingTitleGPU
        case .memory: return strings.monitorRankingTitleMemory
        case .network: return strings.monitorRankingTitleNetwork
        case .energy: return strings.monitorRankingTitleEnergy
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch resolvedContent {
        case .loading:
            loadingView
        case .empty:
            emptyView
        case .failed(let reason):
            failedView(reason: reason)
        case .loaded(let processes):
            loadedView(processes: processes)
        }
    }

    private enum ResolvedContent {
        case loading
        case empty
        case failed(String)
        case loaded([ProcessUsage])
    }

    /// Prefer state matching `kind`; mismatched / collapsed → loading until sample arrives.
    private var resolvedContent: ResolvedContent {
        switch state {
        case .collapsed:
            return .loading
        case .loading:
            return .loading
        case .loaded(let stateKind, let processes):
            guard stateKind == kind else { return .loading }
            if processes.isEmpty { return .empty }
            return .loaded(Array(processes.prefix(Self.displayLimit)))
        case .failed(let stateKind, let reason):
            guard stateKind == kind else { return .loading }
            return .failed(reason)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(format: strings.monitorProcessLoading, title))
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }

    private var emptyView: some View {
        Text(strings.monitorProcessEmpty)
            .font(Theme.Stats.font11Regular)
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
    }

    private func failedView(reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.Stats.up)
            Text("\(title): \(reason)")
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(Theme.Stats.up)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }

    private func loadedView(processes: [ProcessUsage]) -> some View {
        let maxValue = processes.map(\.value).max() ?? 0
        let accent = accentColor
        return VStack(alignment: .leading, spacing: 4) {
            columnHeader
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(processes) { proc in
                        ProcessUsageRankRow(
                            name: proc.name,
                            valueText: ProcessUsageFormatting.valueText(for: proc, kind: kind),
                            share: ProcessUsageShare.fraction(value: proc.value, maxValue: maxValue),
                            accent: accent,
                            icon: ImageThumbnailer.shared.thumbnail(forPID: proc.pid, size: NSSize(width: 44, height: 44)),
                            fallbackSymbol: ProcessUsageIcon.systemImage(forProcessName: proc.name),
                            isArmed: armedPID == proc.pid,
                            canTerminate: ProcessTermination.canTerminate(
                                pid: proc.pid, name: proc.name, ownPID: Self.ownPID
                            ),
                            onIconTap: { handleIconTap(proc) }
                        )
                        if proc.id != processes.last?.id {
                            Divider()
                                .overlay(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 图标点击：第一次进入"待终止"armed 态（图标变红❌），3s 内再次点击则执行终止。
    /// 系统关键进程/自身不可终止，点击不响应。
    private func handleIconTap(_ proc: ProcessUsage) {
        guard ProcessTermination.canTerminate(
            pid: proc.pid, name: proc.name, ownPID: Self.ownPID
        ) else { return }
        if armedPID == proc.pid {
            // 已 armed：确认终止，先复位再后台执行（优雅退出，不阻塞 UI）。
            armedPID = nil
            DispatchQueue.global(qos: .utility).async {
                ProcessTermination.terminate(pid: proc.pid)
            }
        } else {
            armedPID = proc.pid
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 24, height: 1)
            Text(strings.monitorProcessNameHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(title)
                .layoutPriority(1)
            Text(strings.monitorProcessShareHeader)
                .frame(width: 56, alignment: .trailing)
        }
        .font(Theme.Stats.font10Regular)
        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var accentColor: Color {
        switch kind {
        case .cpu: return MonitorCardAccent.color(for: .cpu)
        case .gpu: return MonitorCardAccent.color(for: .gpu)
        case .memory: return MonitorCardAccent.color(for: .memory)
        case .network: return MonitorCardAccent.color(for: .network)
        case .energy: return MonitorCardAccent.color(for: .energy)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if showsSettingsAction {
                FooterButton(label: strings.monitorPreferences, systemImage: "slider.horizontal.3") {
                    onOpenSettings()
                }
            }

            Spacer()
        }
        .padding(.top, 4)
    }
}
