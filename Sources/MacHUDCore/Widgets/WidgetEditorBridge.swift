import AppKit
import HUDKit

/// The widget layer as the layout editor sees it: the widgets on the editor's display as
/// blocks, the types for its Add Widget menu, and moves and adds that go through the same
/// placement as the `widgets` verb and the apps' events.
extension WidgetLayer: LayoutEditorWidgets {
    /// The display whose frame is `screenFrame` (the editor covers one display).
    private func screenIndex(frame screenFrame: CGRect) -> Int? {
        let screens = screens()
        return screens.firstIndex { $0.frame == screenFrame } ?? screens.firstIndex { $0.frame.intersects(screenFrame) }
    }

    func editorWidgets(on screenFrame: CGRect) -> [EditorWidget] {
        guard let index = screenIndex(frame: screenFrame) else { return [] }
        let placed = placements()
        return records.compactMap { r in
            guard let p = placed[r.instance], p.screen == index, let t = type(app: r.app, type: r.type) else { return nil }
            return EditorWidget(id: r.instance, title: t.title, symbol: t.symbol, size: r.size, frame: p.frame)
        }
    }

    func editorWidgetTypes() -> [EditorWidgetType] {
        let records = records
        return types().map { t in
            let placed = records.contains { $0.app == t.app.id && $0.type == t.id }
            return EditorWidgetType(app: t.app.id, appName: t.app.name, type: t.id, title: t.title, symbol: t.symbol,
                                    sizes: t.spec.sizes, canAdd: t.spec.multiple || !placed)
        }
    }

    var editorWidgetGrid: GridSize { grid() }

    func editorMove(_ id: String, to frame: CGRect) -> String? {
        switch place(id, at: frame) {
        case .failure(let error): return error.description
        case .success(let (wanted, at)): return wanted == at ? nil : "That spot is taken; moved to the nearest free one"
        }
    }

    func editorAdd(app: String, type: String, size: HUDWidgetSize, screenFrame: CGRect, done: @escaping (String?) -> Void) {
        let ref = screenIndex(frame: screenFrame).map { screens()[$0].ref }
        add(app: app, type: type, size: size, screen: ref) { result in
            switch result {
            case .success(let (_, note)): done(note)
            case .failure(let error): done(error.description)
            }
        }
    }
}
