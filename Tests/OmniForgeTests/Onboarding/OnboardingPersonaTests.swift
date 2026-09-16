import XCTest
@testable import OmniForge

@MainActor
final class OnboardingPersonaTests: XCTestCase {
    func test_allPersonas_haveNonEmptyFeatures() {
        for persona in OnboardingPersona.allCases {
            XCTAssertFalse(persona.features.isEmpty, "\(persona) features should not be empty")
        }
    }

    func test_allInOne_containsAllAppFeatures() {
        let allInOneFeatures = OnboardingPersona.allInOne.features
        XCTAssertEqual(allInOneFeatures, Set(AppFeature.allCases))
    }

    func test_aiDeveloper_containsCoreAITools() {
        let features = OnboardingPersona.aiDeveloper.features
        XCTAssertTrue(features.contains(.tokenUsage))
        XCTAssertTrue(features.contains(.providerSwitch))
        XCTAssertTrue(features.contains(.promptOptimizer))
        XCTAssertTrue(features.contains(.systemMonitor))
    }

    func test_productivity_containsCoreProductivityTools() {
        let features = OnboardingPersona.productivity.features
        XCTAssertTrue(features.contains(.clipboardHistory))
        XCTAssertTrue(features.contains(.quickPhrase))
        XCTAssertTrue(features.contains(.shelf))
        XCTAssertTrue(features.contains(.stickyNotes))
        XCTAssertTrue(features.contains(.screenshot))
    }

    func test_macGeek_containsSystemAndMouseTools() {
        let features = OnboardingPersona.macGeek.features
        XCTAssertTrue(features.contains(.systemMonitor))
        XCTAssertTrue(features.contains(.keepAwake))
        XCTAssertTrue(features.contains(.cleaner))
        XCTAssertTrue(features.contains(.uninstaller))
        XCTAssertTrue(features.contains(.scrollInverter))
    }

    func test_persona_displayTitleAndDesc_nonEmpty() {
        let zhStrings = Strings.zhHans
        let enStrings = Strings.en

        for persona in OnboardingPersona.allCases {
            XCTAssertFalse(persona.title(in: zhStrings).isEmpty)
            XCTAssertFalse(persona.title(in: enStrings).isEmpty)
            XCTAssertFalse(persona.description(in: zhStrings).isEmpty)
            XCTAssertFalse(persona.description(in: enStrings).isEmpty)
        }
    }
}
