import AppKit
import HUDKit

extension LoadoutEngine {
    /// Puts a sibling app's panel where `apps.<id>.placement` says: in a region, or parked
    /// (from that region, or from the panel's default size against the edge). Called once
    /// the app MacHUD launched is listening. Returns why it could not, or nil.
    @discardableResult
    func applyDefaultPlacement(_ app: ExternalApp, _ placement: AppPlacement) -> String? {
        guard let panelID = placement.panel ?? app.manifest.presentedPanels.first?.id,
              let panel = panels.panel(id: ExternalPanel.id(app: app.id, panel: panelID)) as? ExternalPanel else {
            return "\(app.name) has no panel \(placement.panel ?? "")"
        }
        guard let screen = screen(nil) else { return "no screen" }
        let rest: CGRect
        if let key = placement.region {
            guard let layout = placement.layout.map({ store.layout(named: $0) }) ?? store.activeLayout else {
                return "no layout \(placement.layout ?? "(active)")"
            }
            guard let region = AppPlacement.region(key, in: layout) else { return "no region \(key) in \(layout.name)" }
            rest = regionRect(region, on: screen)
        } else {
            let size = panel.descriptor.defaultSize?.cgSize ?? CGSize(width: 600, height: 400)
            rest = AppPlacement.restFrame(size: size, edge: placement.edge ?? .left, visible: screen.visibleFrame)
        }
        guard placement.isParked else {
            parking.release(.external(panel))
            panel.show()
            return panel.place(in: rest) ? nil : "\(app.name) is not reachable and has no window to move"
        }
        let edge = placement.edge ?? ParkGeometry.nearestEdge(for: rest, in: screen.frame, allowTop: false)
        let target: ParkingController.Target
        if let cooperative = panels.cooperativeParkingTarget(panel.id) {
            target = cooperative
        } else if let window = panel.axWindow() {
            // Parking starts from where the window is; start it from the rest frame.
            window.setCocoaFrame(rest)
            target = .ax(window)
        } else {
            return "\(app.name) is not reachable and has no window to park"
        }
        parking.park(target, id: "app:\(app.id)", label: panel.title, rest: rest, edge: edge,
                     peek: CGFloat(max(placement.peek ?? 0, 0)), screen: screen)
        return nil
    }
}
