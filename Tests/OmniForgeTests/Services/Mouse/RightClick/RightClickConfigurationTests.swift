import XCTest
@testable import OmniForge

final class RightClickConfigurationTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TestRightClickSuite_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_defaultFileExtensions_loadedCorrectly() {
        let config = RightClickConfiguration(defaults: testDefaults)
        XCTAssertEqual(config.fileExtensions, RightClickConfiguration.defaultFileExtensions)
    }

    func test_addAndRemoveFileExtension() {
        let config = RightClickConfiguration(defaults: testDefaults)
        
        // 添加新扩展名（带前导点）
        config.addFileExtension(".vue")
        XCTAssertTrue(config.fileExtensions.contains("vue"))

        // 重复添加不应增加
        let countBefore = config.fileExtensions.count
        config.addFileExtension("vue")
        XCTAssertEqual(config.fileExtensions.count, countBefore)

        // 移除扩展名
        config.removeFileExtension("vue")
        XCTAssertFalse(config.fileExtensions.contains("vue"))

        // 重置为默认
        config.resetFileExtensions()
        XCTAssertEqual(config.fileExtensions, RightClickConfiguration.defaultFileExtensions)
    }

    func test_submenuAndPromotedActions() {
        let config = RightClickConfiguration(defaults: testDefaults)
        
        // 默认折叠在二级菜单
        XCTAssertTrue(config.isSubmenuCollapsed)
        
        config.isSubmenuCollapsed = false
        XCTAssertFalse(config.isSubmenuCollapsed)

        // 提升项测试
        XCTAssertFalse(config.isActionPromoted("newFile"))
        config.setActionPromoted("newFile", isPromoted: true)
        XCTAssertTrue(config.isActionPromoted("newFile"))
        
        config.setActionPromoted("newFile", isPromoted: false)
        XCTAssertFalse(config.isActionPromoted("newFile"))
    }

    func test_favoriteDirectoriesManagement() {
        let config = RightClickConfiguration(defaults: testDefaults)
        let initialCount = config.favoriteDirectories.count

        config.addFavoriteDirectory(name: "我的项目", path: "/Users/test/Projects")
        XCTAssertEqual(config.favoriteDirectories.count, initialCount + 1)
        
        let added = config.favoriteDirectories.last!
        XCTAssertEqual(added.name, "我的项目")
        XCTAssertEqual(added.path, "/Users/test/Projects")

        config.removeFavoriteDirectory(id: added.id)
        XCTAssertEqual(config.favoriteDirectories.count, initialCount)
    }
}
