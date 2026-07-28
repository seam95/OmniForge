protocol TISClient {
    func listInputSources() -> [InputSource]
    func currentInputSourceID() -> String?
    func selectInputSource(id: String) -> Bool
}
