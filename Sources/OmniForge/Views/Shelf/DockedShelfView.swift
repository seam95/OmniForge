import SwiftUI
import UniformTypeIdentifiers

/// Shelf docked under the menu bar icon: compact pill when idle, full card when open.
struct DockedShelfView: View {
    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var l10n = L10n()

    var body: some View {
        // No open/close animation: panel resize and SwiftUI swap lag if animated together.
        Group {
            if shelf.dockedExpanded {
                ShelfView(
                    dismissSystemImage: "chevron.up",
                    dismissHelp: l10n.s.shelfCollapse,
                    onDismiss: { shelf.collapseDocked() },
                    onAccept: { _ in shelf.dockDidAccept() },
                    hidesPin: true
                )
            } else {
                ShelfPill()
            }
        }
        .omniNoFocusRing()
    }
}

/// Collapsed shelf: glass capsule with glyph, count, and expand affordance.
private struct ShelfPill: View {
    @EnvironmentObject private var shelf: ShelfService
    @ObservedObject private var l10n = L10n()
    @Environment(\.colorScheme) private var colorScheme
    @State private var targeted = false
    @State private var hovered = false

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .text, .plainText]

    var body: some View {
        HStack(spacing: 8) {
            leadingGlyph

            if shelf.itemCount > 0 {
                Text("\(shelf.itemCount)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07))
                    )
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(hovered || targeted ? 0.95 : 0.5)
        }
        .padding(.leading, 10)
        .padding(.trailing, 11)
        .padding(.vertical, 8)
        .background(ShelfChrome.pillBackground(colorScheme: colorScheme))
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    targeted ? Color.accentColor.opacity(0.9) : Color.clear,
                    lineWidth: targeted ? 1.4 : 0
                )
        )
        .shadow(
            color: Color.black.opacity(
                targeted
                    ? (colorScheme == .dark ? 0.42 : 0.16)
                    : (colorScheme == .dark ? 0.28 : 0.10)
            ),
            radius: targeted ? 14 : 8,
            x: 0,
            y: targeted ? 6 : 3
        )
        .scaleEffect(targeted ? 1.04 : (hovered ? 1.02 : 1))
        .contentShape(Capsule(style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture { shelf.expandDocked() }
        .help(l10n.s.shelfOpenNow)
        .animation(.easeOut(duration: 0.14), value: targeted)
        .animation(.easeOut(duration: 0.14), value: hovered)
        .animation(.easeOut(duration: 0.16), value: shelf.dockedJustCaught)
        .padding(8)
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            let accepted = shelf.accept(providers: providers)
            if accepted { shelf.dockDidAccept() }
            return accepted
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if shelf.dockedJustCaught {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .symbolRenderingMode(.hierarchical)
        }
    }
}
