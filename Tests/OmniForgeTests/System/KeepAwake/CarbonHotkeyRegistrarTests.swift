import Carbon
import XCTest
@testable import OmniForge

@MainActor
final class CarbonHotkeyRegistrarTests: XCTestCase {

    // MARK: - 注册 / 注销 happy path

    func test_register_returnsTokenAndCallsFunctionTable() throws {
        let functions = FakeCarbonHotkeyFunctions()
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        let token = try registrar.register(keyCode: 40, carbonModifiers: UInt32(cmdKey)) {}

        XCTAssertEqual(functions.registerCalls.count, 1)
        let call = functions.registerCalls[0]
        XCTAssertEqual(call.keyCode, 40)
        XCTAssertEqual(call.modifiers, UInt32(cmdKey))
        XCTAssertNotEqual(token.id, 0)
        XCTAssertNotNil(token.hotKey)
        XCTAssertTrue(registrar.isActive(token))
    }

    func test_unregister_releasesHotkeyAndClearsHandler() throws {
        let functions = FakeCarbonHotkeyFunctions()
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        var fired = 0
        let token = try registrar.register(keyCode: 40, carbonModifiers: 0) {
            fired += 1
        }
        try registrar.unregister(token)

        XCTAssertEqual(functions.unregisterCalls.count, 1)
        XCTAssertEqual(functions.unregisterCalls[0].hotKey, token.hotKey)
        XCTAssertFalse(registrar.isActive(token))

        // 注销后通过 token 派发不再触发 handler。
        registrar.dispatchHotkeyEvent(id: token.id, isKeyUp: true)
        XCTAssertEqual(fired, 0)
    }

    // MARK: - key up 触发；key down 不触发

    func test_keyUpInvokesHandlerOnce() throws {
        let functions = FakeCarbonHotkeyFunctions()
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        var fired = 0
        let token = try registrar.register(keyCode: 1, carbonModifiers: 0) {
            fired += 1
        }

        registrar.dispatchHotkeyEvent(id: token.id, isKeyUp: false)
        XCTAssertEqual(fired, 0, "key down 不应触发 handler")

        registrar.dispatchHotkeyEvent(id: token.id, isKeyUp: true)
        XCTAssertEqual(fired, 1, "key up 应触发一次")

        registrar.dispatchHotkeyEvent(id: token.id, isKeyUp: true)
        XCTAssertEqual(fired, 2)
    }

    // MARK: - 非 noErr：真实 status 上抛，handler 不可用

    func test_registerNonNoErrThrowsStatusAndDoesNotMarkActive() {
        let functions = FakeCarbonHotkeyFunctions(registerStatus: -9878 /* eventHotKeyExistsErr */)
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        var fired = 0
        do {
            _ = try registrar.register(keyCode: 1, carbonModifiers: 0) { fired += 1 }
            XCTFail("应抛错")
        } catch let error as KeepAwakeError {
            if case .hotkeyRegistrationFailed(let status) = error {
                XCTAssertEqual(status, -9878)
            } else {
                XCTFail("错误类型不符：\(error)")
            }
        } catch {
            XCTFail("意外错误：\(error)")
        }

        // 派发事件不应触发 handler。
        registrar.dispatchHotkeyEvent(id: 1, isKeyUp: true)
        XCTAssertEqual(fired, 0)
    }

    func test_unregisterNonNoErrThrowsStatus() throws {
        let functions = FakeCarbonHotkeyFunctions()
        functions.unregisterStatus = -1
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        let token = try registrar.register(keyCode: 1, carbonModifiers: 0) {}

        do {
            try registrar.unregister(token)
            XCTFail("应抛错")
        } catch let error as KeepAwakeError {
            if case .hotkeyUnregistrationFailed(let status) = error {
                XCTAssertEqual(status, -1)
            } else {
                XCTFail("错误类型不符：\(error)")
            }
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    // MARK: - teardown：内部状态清空

    func test_teardownUnregistersAllAndDropsHandlers() throws {
        let functions = FakeCarbonHotkeyFunctions()
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        var fired = 0
        let token = try registrar.register(keyCode: 1, carbonModifiers: 0) { fired += 1 }

        registrar.teardown()

        XCTAssertEqual(functions.unregisterCalls.count, 1)
        XCTAssertEqual(functions.unregisterCalls[0].hotKey, token.hotKey)
        XCTAssertFalse(registrar.isActive(token))

        registrar.dispatchHotkeyEvent(id: token.id, isKeyUp: true)
        XCTAssertEqual(fired, 0)
    }

    // MARK: - 未知 token 派发：无副作用

    func test_dispatchUnknownTokenDoesNothing() {
        let functions = FakeCarbonHotkeyFunctions()
        let registrar = CarbonHotkeyRegistrar(functions: functions)

        registrar.dispatchHotkeyEvent(id: 999, isKeyUp: true)
        // 没有崩溃、没有副作用。
    }
}

// MARK: - Fake function table

private final class FakeCarbonHotkeyFunctions: CarbonHotkeyFunctionTable {
    struct RegisterCall {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    struct UnregisterCall {
        let hotKey: EventHotKeyRef
    }

    var registerStatus: OSStatus = noErr
    var unregisterStatus: OSStatus = noErr

    private(set) var registerCalls: [RegisterCall] = []
    private(set) var unregisterCalls: [UnregisterCall] = []
    private var counter = 0

    init(registerStatus: OSStatus = noErr) {
        self.registerStatus = registerStatus
    }

    func registerEventHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        hotKeyID: EventHotKeyID,
        eventTarget: EventTargetRef,
        options: OptionBits,
        outHotKey: UnsafeMutablePointer<EventHotKeyRef?>
    ) -> OSStatus {
        counter += 1
        // 给出一个稳定的非 nil 不透明 ref。registrar 只把它作为不透明值回传给 unregister。
        let bit = UInt(0xDEAD_0000 + counter)
        outHotKey.pointee = OpaquePointer(UnsafeMutableRawPointer(bitPattern: bit))
        registerCalls.append(RegisterCall(keyCode: keyCode, modifiers: modifiers))
        return registerStatus
    }

    func unregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
        unregisterCalls.append(UnregisterCall(hotKey: hotKey))
        return unregisterStatus
    }
}
