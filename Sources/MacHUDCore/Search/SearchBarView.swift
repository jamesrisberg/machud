import AppKit
import SwiftUI

/// The bar's measurements, shared by the window and the snapshot.
enum SearchBarMetrics {
    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 60
    static let rowHeight: CGFloat = 48
    /// Rows shown before the list scrolls (⌘1–9 reach these).
    static let visibleRows = 9
    static let listPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 20

    /// The bar's height with `rows` results: the field alone when there are none.
    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return fieldHeight }
        return fieldHeight + 1 + CGFloat(min(rows, visibleRows)) * rowHeight + 2 * listPadding
    }

    /// The tallest the bar gets.
    static var maxHeight: CGFloat { height(rows: visibleRows) }
}

/// Row icons: an app's or file's Finder icon (cached by path), a symbol for loadouts and snippets.
@MainActor
enum SearchIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for result: SearchResult) -> NSImage {
        switch result.kind {
        case .app, .file:
            if let cached = cache.object(forKey: result.id as NSString) { return cached }
            let icon = NSWorkspace.shared.icon(forFile: result.id)
            cache.setObject(icon, forKey: result.id as NSString)
            return icon
        case .loadout:
            return NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Loadout") ?? NSImage()
        case .snippet:
            return NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Snippet") ?? NSImage()
        }
    }
}

/// The result rows under the field.
struct SearchResultsView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.key) { index, result in
                        SearchRowView(result: result, index: index, selected: index == model.selection)
                            .id(result.key)
                            .contentShape(Rectangle())
                            .onTapGesture { model.run(row: index, .plain) }
                    }
                }
                .padding(SearchBarMetrics.listPadding)
            }
            .onChange(of: model.selection) { _, _ in
                guard let key = model.selected?.key else { return }
                proxy.scrollTo(key)
            }
        }
    }
}

struct SearchRowView: View {
    let result: SearchResult
    let index: Int
    let selected: Bool

    /// The selected row says what its modifier keys do.
    private var subtitle: String {
        guard selected else { return result.subtitle }
        switch result.kind {
        case .loadout: return "⏎ Apply   ⌥⏎ Preview   ⇧⏎ Clear + Apply"
        case .file: return "\(result.subtitle)   ·   ⌘⏎ Reveal in Finder"
        case .app, .snippet: return result.subtitle
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: SearchIcons.image(for: result))
                .resizable()
                .renderingMode(result.kind == .app || result.kind == .file ? .original : .template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: result.kind == .app || result.kind == .file ? 32 : 22, height: 32)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(result.kind.label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 0.8 : 0.4))
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: SearchBarMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.55) : Color.clear)
        )
    }
}

/// The bar's content: a magnifier and the text field on top, a hairline, the rows below.
/// Lives on the glass in the window, on a dark stand-in in a snapshot.
final class SearchBarContentView: NSView {
    let field = NSTextField()
    private let separator = NSView()
    private let list: NSHostingView<SearchResultsView>

    init(model: SearchModel, frame: CGRect) {
        list = NSHostingView(rootView: SearchResultsView(model: model))
        super.init(frame: frame)
        let m = SearchBarMetrics.self
        let top = frame.height - m.fieldHeight

        let icon = NSImageView(frame: CGRect(x: 20, y: top + (m.fieldHeight - 24) / 2, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        icon.autoresizingMask = [.minYMargin]
        addSubview(icon)

        field.frame = CGRect(x: 56, y: top + (m.fieldHeight - 32) / 2, width: frame.width - 76, height: 32)
        field.autoresizingMask = [.width, .minYMargin]
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.textColor = .white
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "Search apps, files, snippets and loadouts",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 24, weight: .light)])
        addSubview(field)

        separator.frame = CGRect(x: 0, y: top - 1, width: frame.width, height: 1)
        separator.autoresizingMask = [.width, .minYMargin]
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(separator)

        list.frame = CGRect(x: 0, y: 0, width: frame.width, height: max(0, top - 1))
        list.autoresizingMask = [.width, .height]
        addSubview(list)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
