import SwiftUI

extension EnvironmentValues {
    /// Draws controls with solid fills and standard button styles instead of
    /// glass. Offscreen renders cannot draw glass, so screenshots set this.
    @Entry public var sweepSolidControls = false
}

extension View {
    /// Liquid Glass on macOS 26 and later, a system material before that, and a
    /// solid background when Reduce Transparency is on. Glass is for controls
    /// and chrome, never for content, and never on top of other glass.
    public func glassOrMaterial<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassOrMaterial(shape: shape, interactive: interactive, tint: tint))
    }

    /// Glass in the standard panel shape (corner radius 20).
    public func glassPanel() -> some View {
        glassOrMaterial(in: RoundedRectangle(cornerRadius: SweepMetric.panelRadius, style: .continuous))
    }

    /// The primary action style: prominent glass on macOS 26, bordered prominent before.
    public func prominentActionStyle() -> some View {
        modifier(ProminentActionStyle())
    }

    /// A secondary glass button on macOS 26, bordered before.
    public func secondaryActionStyle() -> some View {
        modifier(SecondaryActionStyle())
    }

    /// A plain card for content: 12-point corners on the control background. Not glass.
    public func sweepCard(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SweepMetric.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SweepMetric.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

private struct GlassOrMaterial<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.sweepSolidControls) private var solidControls
    let shape: S
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        if reduceTransparency || solidControls {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.4), lineWidth: 0.5))
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

private struct ProminentActionStyle: ViewModifier {
    @Environment(\.sweepSolidControls) private var solidControls

    func body(content: Content) -> some View {
        if solidControls {
            content.buttonStyle(.borderedProminent)
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct SecondaryActionStyle: ViewModifier {
    @Environment(\.sweepSolidControls) private var solidControls

    func body(content: Content) -> some View {
        if solidControls {
            content.buttonStyle(.bordered)
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Groups neighbouring glass shapes so they blend on macOS 26. A plain container before that.
public struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Lets a glass shape morph between positions inside a `GlassGroup` on macOS 26.
    @ViewBuilder
    public func glassMorphID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            matchedGeometryEffect(id: id, in: namespace)
        }
    }
}
