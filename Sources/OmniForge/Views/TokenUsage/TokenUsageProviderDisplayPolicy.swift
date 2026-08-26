import Foundation

/// Token 面板/弹层的 provider 展示候选集。
///
/// 限额快照表示“已拿到可展示限额”；凭证状态表示“用户已配置但可能无有效套餐/配额”。
/// 两者合并后再按用户排序和显隐偏好过滤，避免凭证类 provider 从 UI 中消失。
enum TokenUsageProviderDisplayPolicy {
    static let credentialDrivenProviders: Set<TokenUsageProvider> = [.opencode, .arkCodingPlan]

    static func providers(
        providerOrder: [TokenUsageProvider],
        configuredLimitProviders: Set<TokenUsageProvider>,
        credentialConfiguredProviders: Set<TokenUsageProvider>,
        showingDeepSeekBalance: Bool,
        hiddenProviders: Set<TokenUsageProvider>
    ) -> [TokenUsageProvider] {
        var candidates = configuredLimitProviders
        candidates.formUnion(credentialConfiguredProviders.intersection(credentialDrivenProviders))
        if showingDeepSeekBalance {
            candidates.insert(.deepSeek)
        }
        return providerOrder.filter { candidates.contains($0) && !hiddenProviders.contains($0) }
    }

    static func displayableCardProviders(
        from providers: [TokenUsageProvider],
        limits: [TokenUsageProvider: ProviderUsageLimits],
        credentialConfiguredProviders: Set<TokenUsageProvider>,
        showingDeepSeekBalance: Bool
    ) -> [TokenUsageProvider] {
        providers.filter { provider in
            limits[provider] != nil
                || (credentialDrivenProviders.contains(provider) && credentialConfiguredProviders.contains(provider))
                || (provider == .deepSeek && showingDeepSeekBalance)
        }
    }
}

/// 凭证类 provider 的只读状态读取。
///
/// 读取发生在 SwiftUI 生命周期事件中，不放到 body 计算链路，避免渲染期反复访问 Keychain。
enum TokenUsageCredentialStateReader {
    static func configuredProviders(
        opencodeStore: OpencodeAPIKeyStoring? = OpencodeKeychainAPIKeyStore(),
        arkStore: ArkCredentialsStoring? = ArkKeychainStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<TokenUsageProvider> {
        var providers: Set<TokenUsageProvider> = []

        let opencodeKey = opencodeStore
            .flatMap { try? $0.readAPIKey() }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let opencodeEnvKey = environment["OPENCODE_GO_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if opencodeKey?.isEmpty == false || opencodeEnvKey?.isEmpty == false {
            providers.insert(.opencode)
        }

        let storedArkCredentials = arkStore.flatMap { try? $0.readCredentials() }
        let arkAccessKey = environment["VOLCENGINE_ACCESS_KEY"]
            ?? environment["ARK_AK"]
            ?? environment["VOLCENGINE_AK"]
        let arkSecretKey = environment["VOLCENGINE_SECRET_KEY"]
            ?? environment["ARK_SK"]
            ?? environment["VOLCENGINE_SK"]
        let normalizedArkAccessKey = arkAccessKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArkSecretKey = arkSecretKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if storedArkCredentials?.isValid == true
            || (normalizedArkAccessKey?.isEmpty == false && normalizedArkSecretKey?.isEmpty == false) {
            providers.insert(.arkCodingPlan)
        }

        return providers
    }
}
