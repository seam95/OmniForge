import Carbon
import Foundation

final class CarbonTISClient: TISClient {
    private func stringProperty(_ tis: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(tis, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func boolProperty(_ tis: TISInputSource, _ key: CFString) -> Bool? {
        guard let ptr = TISGetInputSourceProperty(tis, key) else { return nil }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private func selectInputSource(propertyKey: CFString, value: String) -> Bool {
        let properties = [propertyKey as String: value] as NSDictionary
        guard let unmanaged = TISCreateInputSourceList(properties, false) else { return false }
        let list = unmanaged.takeRetainedValue() as NSArray
        guard let first = list.firstObject else { return false }

        let tis: TISInputSource = unsafeBitCast(first as AnyObject, to: TISInputSource.self)
        return TISSelectInputSource(tis) == noErr
    }

    func listInputSources() -> [InputSource] {
        autoreleasepool {
            guard let unmanaged = TISCreateInputSourceList(nil, false) else { return [] }
            let list = unmanaged.takeRetainedValue() as NSArray

            return list.compactMap { item in
                let tis: TISInputSource = unsafeBitCast(item as AnyObject, to: TISInputSource.self)

                let enabled = boolProperty(tis, kTISPropertyInputSourceIsEnabled) ?? true
                let selectable = boolProperty(tis, kTISPropertyInputSourceIsSelectCapable) ?? true
                guard enabled, selectable else { return nil }

                if let category = stringProperty(tis, kTISPropertyInputSourceCategory),
                   category != (kTISCategoryKeyboardInputSource as String)
                {
                    return nil
                }

                // 很多第三方/系统输入法以「KeyboardInputMode」形式出现（例如拼音/微信输入法），
                // 这类条目在系统输入法切换菜单里是可见且可切换的；其 InputSourceID 可能非唯一，
                // 因此需要优先使用 InputModeID 作为稳定且唯一的标识。

                let type = stringProperty(tis, kTISPropertyInputSourceType)
                let id: String
                if type == (kTISTypeKeyboardInputMode as String) {
                    id = stringProperty(tis, kTISPropertyInputModeID)
                        ?? stringProperty(tis, kTISPropertyInputSourceID)
                        ?? ""
                } else {
                    id = stringProperty(tis, kTISPropertyInputSourceID)
                        ?? stringProperty(tis, kTISPropertyInputModeID)
                        ?? ""
                }
                guard !id.isEmpty else { return nil }

                let name = stringProperty(tis, kTISPropertyLocalizedName) ?? id
                return InputSource(id: id, name: name, isSelectable: selectable, isEnabled: enabled, icon: nil)
            }
        }
    }

    func currentInputSourceID() -> String? {
        guard let tis = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let type = stringProperty(tis, kTISPropertyInputSourceType)
        if type == (kTISTypeKeyboardInputMode as String) {
            return stringProperty(tis, kTISPropertyInputModeID)
                ?? stringProperty(tis, kTISPropertyInputSourceID)
        }
        return stringProperty(tis, kTISPropertyInputSourceID)
            ?? stringProperty(tis, kTISPropertyInputModeID)
    }

    func selectInputSource(id: String) -> Bool {
        if selectInputSource(propertyKey: kTISPropertyInputSourceID, value: id) {
            return true
        }
        return selectInputSource(propertyKey: kTISPropertyInputModeID, value: id)
    }
}
