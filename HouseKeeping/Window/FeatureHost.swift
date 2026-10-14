import AnalyzeUI
import JunkUI
import OptimizeUI
import StatusUI
import SweepKit
import SwiftUI
import UninstallUI

/// Hosts the tools that live in their own SweepKit modules.
struct FeatureHost: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection

    var body: some View {
        switch section {
        case .clean: JunkView(engine: model.engine, privileged: model.privileged)
        case .uninstall: UninstallView(engine: model.engine, privileged: model.privileged)
        case .optimize: OptimizeView(engine: model.engine, privileged: model.privileged)
        case .analyze: AnalyzeView(engine: model.engine)
        case .status: StatusView(engine: model.engine)
        case .overview, .devCaches, .projects, .history: EmptyView()
        }
    }
}
