import AppKit
import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.omniforge.app", category: "Clothesline")

/// 挂在绳上的一张截图。文件永不移动：绳子只是文件的视图。
struct PeggedPhoto: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// 每张照片都挂得有点歪。
    let tilt: Double
    var falling = false
    /// 飞行途中：真卡先隐藏，动画卡接管。
    var flying = false

    static func == (a: PeggedPhoto, b: PeggedPhoto) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }

    /// 随机倾斜角（±2.5°）。种子注入留给测试与视图层，这里只负责随机。
    static func makeTilt() -> Double {
        Double.random(in: -2.5...2.5)
    }
}

protocol ClotheslineSoundPlaying: AnyObject {
    func play(name: String, volume: Float)
}

final class SystemSoundPlayer: ClotheslineSoundPlaying {
    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    func play(name: String, volume: Float) {
        // NSSound(named:) 返回共享实例，拷贝一份避免音量与播放状态互相踩踏。
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    func playTrash() {
        guard let sound = Self.trashSound?.copy() as? NSSound else { return }
        sound.play()
    }
}

@MainActor
final class ClotheslineManager: ObservableObject {
    @Published private(set) var items: [PeggedPhoto] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// 复制完成角标文案；装配层写入 l10n 值（Task 12），默认用系统词。
    var copiedLabel: String = "Copied"
    /// 绳子是否滑入视野（视图层据此做位移动画）。
    @Published var revealed = false

    /// 卡片帧（窗口坐标），视图上报；面板据此做「仅照片区接收鼠标」。
    var hitRects: [UUID: CGRect] = [:]
    var maxItems = 8
    var liveCount: Int { items.filter { !$0.falling }.count }

    var onFall: ((PeggedPhoto) -> Void)?

    private let userDefaults: UserDefaults
    private let pasteboard: PasteboardWriting
    private let thumbnailProvider: (URL) -> NSImage?
    private let soundPlayer: ClotheslineSoundPlaying
    private let inboxFolderProvider: () -> URL?
    private let now: () -> Date
    /// 自家写入排除集：save/hang 意图落盘的路径，watcher 不得自动挂绳。
    private var ownWrites: Set<String> = []

    var soundOn: Bool {
        get {
            // bool(forKey:) 对未设置键返回 false，与「默认开」无法区分，
            // 因此先用 object(forKey:) 判断是否真的写入过。
            userDefaults.object(forKey: UserDefaultsKeys.screenshotClotheslineSoundOn) == nil
                ? false
                : userDefaults.bool(forKey: UserDefaultsKeys.screenshotClotheslineSoundOn)
        }
        set { userDefaults.set(newValue, forKey: UserDefaultsKeys.screenshotClotheslineSoundOn) }
    }

    init(userDefaults: UserDefaults = .standard,
         pasteboard: PasteboardWriting = SystemPasteboardWriter(),
         thumbnailProvider: @escaping (URL) -> NSImage? = { makePeggedThumbnail($0, maxPixels: 480) },
         soundPlayer: ClotheslineSoundPlaying = SystemSoundPlayer(),
         inboxFolderProvider: @escaping () -> URL? = { nil },
         now: @escaping () -> Date = Date.init) {
        self.userDefaults = userDefaults
        self.pasteboard = pasteboard
        self.thumbnailProvider = thumbnailProvider
        self.soundPlayer = soundPlayer
        self.inboxFolderProvider = inboxFolderProvider
        self.now = now
        restore()
    }

    // MARK: 挂载与掉落

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = thumbnailProvider(url)
        else { return nil }
        var item = PeggedPhoto(url: url, thumb: thumb, tilt: PeggedPhoto.makeTilt())
        item.flying = flying
        items.append(item)
        // 挂满时最旧一张从绳尾掉落。
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            drop(oldest.id, quietly: true)
        }
        save()
        if !quietly { soundPlayer.play(name: "Tink", volume: 0.35) }
        return item.id
    }

    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { soundPlayer.play(name: "Pop", volume: 0.25) }
        // deadline 存的是调用瞬间：避免测试注入的假时钟与真实 Task 唤醒时间错位。
        let deadline = now().addingTimeInterval(0.6)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.now() >= deadline - 0.05 else { return }
            self.items.removeAll { $0.id == id }
        }
    }

    /// 「全部取下」：同步标记全部掉落，保证 liveCount 立即归零；
    /// 级联错开动画由视图层按索引延迟播放（状态机不承担动画节拍）。
    func clearAll() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            drop(item.id, quietly: n > 0)
        }
    }

    /// 文件被删/移走的照片自行掉落。
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: 单张动作

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        if let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([entry])
        copiedID = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.copiedID == id else { return }
            self.copiedID = nil
        }
    }

    func openInDefaultApp(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Markup 编辑服务钩子（Task 11 注入真身）。
    var markupEditor: ((URL) -> Void)?

    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        markupEditor?(item.url)
    }

    func trash(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if soundOn, let player = soundPlayer as? SystemSoundPlayer { player.playTrash() }
            drop(id, quietly: true)
        } catch {
            log.error("废纸篓失败 \(item.url.lastPathComponent, privacy: .public)")
            NSSound.beep()
        }
    }

    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }),
              let folder = inboxFolderProvider()
        else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// 角标 × 与右键「取下/丢弃」共用入口。
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox 模式下「存到桌面」：移出文件并离绳。
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("存桌面失败 \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    func revealInFinder(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Markup 写回后刷新缩略图。
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = thumbnailProvider(url)
        else { return }
        items[i].thumb = thumb
    }

    // MARK: 排除集

    /// 归一路径形态：/tmp、/var 等 firmlink 让同一文件有两种路径写法
    /// （登记侧来自管线 saver，消费侧来自 watcher 的真实目录列举），
    /// 不归一则排除集永不命中。对真实存在的文件，resolvingSymlinksInPath
    /// 会把 /private 前缀与非前缀形态归一到同一结果。
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func noteOwnWrite(_ path: String) { ownWrites.insert(Self.normalizedPath(path)) }

    @discardableResult
    func consumeOwnWrite(_ url: URL) -> Bool { ownWrites.remove(Self.normalizedPath(url.path)) != nil }

    // MARK: 微风

    /// 每隔随机 7–16s 吹一阵；细节让绳子像物件而非控件。
    func startBreeze() {
        let delay = Double.random(in: 7...16)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.startBreeze()
        }
    }

    // MARK: 持久化

    private func save() {
        userDefaults.set(items.filter { !$0.falling }.map(\.url.path),
                         forKey: UserDefaultsKeys.screenshotClotheslineItems)
    }

    private func restore() {
        let paths = userDefaults.stringArray(forKey: UserDefaultsKeys.screenshotClotheslineItems) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            hang(URL(fileURLWithPath: path), quietly: true)
        }
    }

    // MARK: 内部

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

/// CGImageSource 缩略图：解码限尺寸，主线程外可用的同步实现。
func makePeggedThumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
