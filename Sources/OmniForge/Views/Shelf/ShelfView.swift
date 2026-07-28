import SwiftUI
import UniformTypeIdentifiers

/// Floating / docked shelf card: header, tile grid, quiet footer.
/// Visual language leans Control Center / system popover — not a dashed HUD tray.
struct ShelfView: View {
    /// Floating shelf closes; docked shelf collapses to its pill instead.
    var dismissSystemImage: String = "xmark"
    var dismissHelp: String? = nil
    var onDismiss: (() -> Void)? = nil
    /// Called with the provider count after a drop is accepted (docked flash hook).
    var onAccept: ((Int) -> Void)? = nil
    /// When true, hides the pin control (docked shelf does not pin).
    var hidesPin: Bool = false

    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var l10n = L10n()
    @Environment(\.colorScheme) private var colorScheme
    @State private var targeted = false

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .text, .plainText]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            tiles
            if !shelf.items.isEmpty {
                bottomBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, shelf.items.isEmpty ? 12 : 10)
        .frame(width: ShelfChrome.panelWidth)
        .background(ShelfChrome.panelBackground(colorScheme: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: ShelfChrome.panelCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShelfChrome.panelCorner, style: .continuous)
                .strokeBorder(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.85)
                        : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    lineWidth: isDropTargeted ? 1.5 : 0.6
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.40 : 0.12),
            radius: isDropTargeted ? 20 : 14,
            x: 0,
            y: isDropTargeted ? 10 : 6
        )
        .overlay(alignment: .topLeading) {
            topMoveHandle
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
        .animation(.easeOut(duration: 0.18), value: shelf.items.isEmpty)
        .onHover { inside in
            shelf.setPointerInsidePanel(inside)
        }
        .onChange(of: targeted) { _, isTargeted in
            shelf.setDropTargeted(isTargeted)
        }
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            let accepted = shelf.accept(providers: providers)
            if accepted {
                shelf.noteInteraction()
                onAccept?(providers.count)
            }
            return accepted
        }
    }

    private var isDropTargeted: Bool {
        targeted || shelf.dropTargeted
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !shelf.items.isEmpty, shelf.selection.isEmpty {
                    Text("\(shelf.itemCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07))
                        )
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(WindowMoveHandle())

            if !hidesPin {
                ShelfHeaderButton(
                    systemImage: shelf.isPinned ? "pin.fill" : "pin",
                    isActive: shelf.isPinned,
                    help: shelf.isPinned ? l10n.s.shelfUnpin : l10n.s.shelfPin
                ) {
                    shelf.togglePin()
                }
            }

            ShelfHeaderButton(
                systemImage: dismissSystemImage,
                help: dismissHelp ?? l10n.s.menuClose
            ) {
                (onDismiss ?? { shelf.hide() })()
            }
        }
    }

    private var topMoveHandle: some View {
        WindowMoveHandle(acceptsDrops: true)
            .frame(width: ShelfChrome.panelWidth - (hidesPin ? 52 : 86), height: 48)
    }

    private var title: String {
        shelf.selection.isEmpty
            ? l10n.s.shelfTitle
            : String(format: l10n.s.shelfSelectedFormat, shelf.selection.count)
    }

    // MARK: - Tiles / empty

    @ViewBuilder
    private var tiles: some View {
        if shelf.items.isEmpty {
            emptyState
        } else {
            ShelfTilesView(
                items: shelf.visibleItems,
                selection: shelf.selection,
                expandedBatches: shelf.expandedBatches
            )
            .frame(height: ShelfChrome.tileAreaHeight)
        }
    }

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                    lineWidth: isDropTargeted ? 1.2 : 0.8
                )

            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05))
                        .frame(width: 44, height: 44)
                    Image(systemName: isDropTargeted ? "plus" : "arrow.down.doc")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }

                Text(l10n.s.shelfEmpty)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        }
        .frame(height: ShelfChrome.tileAreaHeight)
        .overlay(WindowMoveHandle(acceptsDrops: true))
    }

    // MARK: - Footer

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(l10n.s.shelfHint)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: trashAction) {
                Label(
                    shelf.selection.isEmpty ? l10n.s.shelfClearAll : l10n.s.shelfRemoveSelected,
                    systemImage: shelf.selection.isEmpty ? "trash" : "trash.fill"
                )
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(shelf.selection.isEmpty ? l10n.s.shelfClearAll : l10n.s.shelfRemoveSelected)
        }
        .padding(.top, 2)
    }

    private func trashAction() {
        if shelf.selection.isEmpty {
            shelf.clear()
        } else {
            shelf.removeItems(Array(shelf.selection))
        }
    }
}
