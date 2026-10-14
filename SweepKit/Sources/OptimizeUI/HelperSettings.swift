import AppKit
import Observation
import SweepDesign
import SweepKit
import SweepOptimize
import SwiftUI

/// What the Settings window needs to install, remove and watch the admin helper.
@MainActor
@Observable
public final class HelperSettingsModel {
    public private(set) var status: HelperStatus
    /// Set when macOS refused the last install or removal.
    public private(set) var errorMessage: String?
    public private(set) var isWorking = false
    /// False against a fixture home, where the helper can never be installed.
    public let isAvailable: Bool

    private let registration: any HelperRegistering
    private let onChange: @MainActor () -> Void

    /// - Parameter onChange: called after the helper was installed or removed.
    public init(context: SweepContext, registration: (any HelperRegistering)? = nil, onChange: @escaping @MainActor () -> Void = {}) {
        let registration = registration ?? (context.isFixture ? NoHelperRegistration() : HelperRegistration())
        self.registration = registration
        self.onChange = onChange
        isAvailable = !context.isFixture
        status = registration.status()
    }

    /// Shares the client's registration, and tells the client when it changes.
    public convenience init(client: HelperClient) {
        self.init(context: client.context, registration: client.registration) { client.resetHelperProbe() }
    }

    public var statusText: String {
        isAvailable ? status.title : "Not available with a fixture home"
    }

    public var explanation: String {
        switch status {
        case .enabled:
            "Admin tasks run without a password prompt. The helper accepts only House Keeping's fixed list of tasks, only from House Keeping, and quits when it is idle."
        case .requiresApproval:
            "Turn House Keeping on under Allow in the Background in System Settings to finish."
        case .notRegistered:
            "Without the helper, admin tasks ask for your password each time. With it, macOS asks you to approve House Keeping once in Login Items."
        case .notFound:
            "This build does not include the helper. Admin tasks ask for your password each time."
        }
    }

    public func refresh() {
        status = registration.status()
    }

    /// Registers the helper daemon. macOS then asks for approval in Login Items.
    public func install() {
        guard isAvailable, !isWorking else { return }
        errorMessage = nil
        do {
            try registration.register()
        } catch {
            errorMessage = "macOS did not accept the helper: \(error.localizedDescription) Admin tasks keep asking for your password."
        }
        refresh()
        onChange()
    }

    public func remove() async {
        guard isAvailable, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await registration.unregister()
        } catch {
            errorMessage = "The helper could not be removed: \(error.localizedDescription)"
        }
        isWorking = false
        refresh()
        onChange()
    }

    public func openLoginItems() {
        HelperRegistration.openLoginItemsSettings()
    }
}

/// The helper's row in Settings: its state, one line of explanation and one button.
public struct HelperSettingsView: View {
    @State private var model: HelperSettingsModel

    public init(model: HelperSettingsModel) {
        _model = State(initialValue: model)
    }

    public init(client: HelperClient) {
        self.init(model: HelperSettingsModel(client: client))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SweepMetric.grid) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: model.status == .enabled ? "checkmark.shield" : "lock.shield")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Admin helper")
                    Text(model.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                action
            }
            Text(model.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sweepAnimation(value: model.status)
        .onAppear { model.refresh() }
        // Approval happens in System Settings; pick it up when House Keeping comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    @ViewBuilder
    private var action: some View {
        if model.isAvailable {
            switch model.status {
            case .notRegistered:
                Button("Install Helper") { model.install() }
            case .requiresApproval:
                Button("Open Login Items") { model.openLoginItems() }
            case .enabled:
                Button("Remove Helper") { Task { await model.remove() } }
                    .disabled(model.isWorking)
            case .notFound:
                EmptyView()
            }
        }
    }
}
