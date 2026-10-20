import XCTest
@testable import OmniForge

/// 模型图像能力判定 — 对齐 cc-switch v4.0.16 的 fail-open 口径。
final class ModelImageCapabilityTests: XCTestCase {
    func test_unknownModelsFailOpenToImage() {
        for model in ["deepseek-v4.1-flash", "claude-opus-5", "gpt-6-astra", "custom-alias"] {
            XCTAssertEqual(
                ModelImageCapability.inputModalities(for: model),
                ["text", "image"],
                "\(model) 未确认，必须 fail-open"
            )
        }
    }

    func test_confirmedTextOnlyModelsStayText() {
        for model in [
            "deepseek-chat",
            "deepseek/deepseek-chat",
            "deepseek-reasoner",
            "GLM-5.2[1M]",
            "qwen/qwen3-coder-plus",
            "MiniMax-M2.7-Highspeed",
            "step-3.5-flash-2603",
        ] {
            XCTAssertEqual(
                ModelImageCapability.inputModalities(for: model),
                ["text"],
                "\(model) 属于确认纯文本名单"
            )
        }
    }

    func test_visionVariantsAndLegacyAliasesFailOpen() {
        // 精确尾段匹配：视觉变体与旧别名都不能被纯文本名单误伤。
        for model in [
            "glm-5.2v",
            "glm-5.3v",
            "deepseek-v4-flash",
            "deepseek/deepseek-v4-pro",
            "qwen3-coder-vl",
            "kimi-k3",
        ] {
            XCTAssertEqual(
                ModelImageCapability.inputModalities(for: model),
                ["text", "image"],
                "\(model) 不在确认名单，必须 fail-open"
            )
        }
    }

    func test_explicitDeclarationWins() {
        XCTAssertEqual(
            ModelImageCapability.inputModalities(for: "deepseek-chat", declared: ["text", "image"]),
            ["text", "image"],
            "显式声明优先于名单"
        )
        XCTAssertEqual(
            ModelImageCapability.inputModalities(for: "kimi-k3", declared: ["text"]),
            ["text"]
        )
        // 声明会归一化（小写、去空白）。
        XCTAssertEqual(
            ModelImageCapability.inputModalities(for: "kimi-k3", declared: [" Text ", "IMAGE"]),
            ["text", "image"]
        )
    }

    func test_emptyOrWhitespaceDeclarationFallsBackToInference() {
        XCTAssertEqual(
            ModelImageCapability.inputModalities(for: "deepseek-chat", declared: []),
            ["text"]
        )
        XCTAssertEqual(
            ModelImageCapability.inputModalities(for: "kimi-k3", declared: ["  "]),
            ["text", "image"]
        )
    }
}
