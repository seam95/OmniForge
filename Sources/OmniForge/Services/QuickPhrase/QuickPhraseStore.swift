import Foundation

protocol QuickPhraseStore {
    func loadPhrases() -> [QuickPhraseEntry]
    func savePhrase(_ phrase: QuickPhraseEntry)
    func deletePhrase(id: UUID)
    func updatePhrase(_ phrase: QuickPhraseEntry)
    func releaseMemory()
}
