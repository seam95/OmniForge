final class FakeTISClient: TISClient {
    private var sources: [InputSource]
    private var currentIDValue: String?

    private(set) var listInputSourcesCallCount = 0
    private(set) var currentInputSourceIDCallCount = 0

    init(inputSources: [InputSource], currentID: String?) {
        self.sources = inputSources
        self.currentIDValue = currentID
    }

    func listInputSources() -> [InputSource] {
        listInputSourcesCallCount += 1
        return sources
    }

    func currentInputSourceID() -> String? {
        currentInputSourceIDCallCount += 1
        return currentIDValue
    }

    func selectInputSource(id: String) -> Bool {
        guard sources.contains(where: { $0.id == id }) else { return false }
        currentIDValue = id
        return true
    }
}
