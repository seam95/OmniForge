import Foundation
import Combine

final class ProcessBreakdownCoordinator: ObservableObject {
    @Published private(set) var expandedKind: ProcessMetricKind? = nil
    var onToggle: ((ProcessMetricKind?) -> Void)?

    func toggle(_ kind: ProcessMetricKind) {
        if expandedKind == kind {
            expandedKind = nil
            onToggle?(nil)
        } else {
            expandedKind = kind
            onToggle?(kind)
        }
    }

    func open(_ kind: ProcessMetricKind) {
        expandedKind = kind
        onToggle?(kind)
    }

    func close() {
        expandedKind = nil
        onToggle?(nil)
    }
}
