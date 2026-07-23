import AppKit
import SwiftUI

import AgentGlanceCore

/// Two-layer notch background replacing the flat black fill: a Liquid Glass
/// backdrop under a black scrim that stays fully opaque across the bar band —
/// so the camera cutout never shows — and fades toward translucent glass
/// going down, like the Siri orb.
///
/// The backdrop is a self-owned `CABackdropLayer` running the same private
/// `glassBackground` filter `NSGlassEffectView` uses internally. The official
/// wrappers are unusable here: SwiftUI's `glassEffect` samples within the
/// window (flat gray in this clear borderless panel), and `NSGlassEffectView`
/// continuously re-commits its filter values, clobbering any tuning. Owning
/// the layer and filter outright is the only arrangement where our blur,
/// transparency, and refraction values actually hold.
struct NotchGlassBackground: View {
    let silhouette: HangingNotchShape
    /// Height of the strip that must stay pure black (`layout.height`).
    let barBandHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backdrop
                silhouette.fill(scrimGradient(height: max(proxy.size.height, 1)))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var backdrop: some View {
        if NotchCustomGlassView.isSupported {
            NotchCustomGlassBackdrop()
        } else {
            NotchVisualEffectBackdrop()
        }
    }

    /// The scrim renders as an elliptical gradient whose center sits at
    /// `scrimCenterY` (unit space, negative = above the notch): the
    /// iso-opacity bands become arcs that dip lower mid-panel — the curved
    /// black cap of the Siri orb — instead of ruler-straight lines. Vertical
    /// stop positions map to radius fractions relative to that center; the
    /// clamp keeps the center inside the solid band so the mirrored region
    /// above it can never reach visible glass.
    private func scrimGradient(height: CGFloat) -> EllipticalGradient {
        let stops = NotchGlassStyle.scrimStops(
            height: height,
            solidBandHeight: barBandHeight + NotchGlassStyle.solidBandOverlap
        )
        let centerY = NotchGlassStyle.scrimCenterY
        let reach = 1 - centerY
        return EllipticalGradient(
            stops: stops.map {
                Gradient.Stop(
                    color: .black.opacity($0.opacity),
                    location: ($0.location - centerY) / reach
                )
            },
            center: UnitPoint(x: 0.5, y: centerY),
            startRadiusFraction: 0,
            endRadiusFraction: reach
        )
    }
}

private struct NotchCustomGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NotchCustomGlassView {
        NotchCustomGlassView()
    }

    func updateNSView(_ view: NotchCustomGlassView, context: Context) {}
}

/// Self-owned Liquid Glass, replicating the exact private layer recipe found
/// inside `NSGlassEffectView` (recovered via keyed-archive inspection):
///
///     CABackdropLayer (name "@0", windowServerAware, glassBackground filter)
///       └── CASDFLayer (name "@0", effect: CASDFOutputEffect(maximum: 1))
///             └── CALayer
///                   └── CASDFElementLayer (cornerRadius, continuous curve)
///
/// The `glassBackground` filter reads its lens geometry from the signed
/// distance field produced by the sublayer named by `inputSourceSublayerName`
/// ("@0") — without that SDF stack the filter blurs but never refracts. We
/// own every object, so unlike `NSGlassEffectView`, nothing re-commits values
/// over our tuning. Everything resolves via runtime lookup: this compiles on
/// any SDK, and `isSupported` reports false wherever the private machinery is
/// missing (then pre-26 systems fall back to the visual-effect blur).
final class NotchCustomGlassView: NSView {
    static let isSupported: Bool =
        makeGlassFilter() != nil
            && NSClassFromString("CASDFLayer") is CALayer.Type
            && NSClassFromString("CASDFElementLayer") is CALayer.Type
            && NSClassFromString("CASDFOutputEffect") is NSObject.Type

    private let shapeMask = CAShapeLayer()
    private var backdrop: CALayer?
    private var sdfLayer: CALayer?
    private var sdfContainer: CALayer?
    private var sdfElement: CALayer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        installBackdropIfNeeded()
    }

    /// The backdrop is hosted as a plain sublayer, never as the view's
    /// backing layer: AppKit stamps backing layers with a debug name
    /// ("CABackdropLayer: …View"), clobbering the "@0" name that pairs the
    /// backdrop with the SDF source the glassBackground filter resolves via
    /// `inputSourceSublayerName`.
    private func installBackdropIfNeeded() {
        guard backdrop == nil, let hostLayer = layer else { return }
        guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let sdfType = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementType = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let effectType = NSClassFromString("CASDFOutputEffect") as? NSObject.Type,
              let filter = Self.makeGlassFilter() else {
            NSLog("AgentGlance custom glass unavailable; backdrop not installed")
            return
        }

        let glass = backdropType.init()
        glass.name = "@0"
        glass.filters = [filter]
        // CALayer KVC tolerates arbitrary keys, so these are safe no-ops if
        // the private layer stops recognizing them.
        glass.setValue(true, forKey: "windowServerAware")
        glass.setValue(false, forKey: "allowsGroupBlending")
        glass.setValue(true, forKey: "allowsFilteredLuma")
        glass.setValue(0.5, forKey: "scale")
        glass.mask = shapeMask

        let sdf = sdfType.init()
        sdf.name = "@0"
        let effect = effectType.init()
        effect.setValue(1, forKey: "maximum")
        sdf.setValue(effect, forKey: "effect")

        let container = CALayer()
        let element = elementType.init()
        element.cornerRadius = HangingNotchMetrics.bottomCornerRadius
        element.cornerCurve = .continuous
        element.setValue(true, forKey: "hitTestsAsFill")

        container.addSublayer(element)
        sdf.addSublayer(container)
        glass.addSublayer(sdf)
        hostLayer.addSublayer(glass)

        backdrop = glass
        sdfLayer = sdf
        sdfContainer = container
        sdfElement = element
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        shapeMask.frame = bounds
        shapeMask.path = HangingNotchGeometry.path(
            in: bounds,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
        sdfLayer?.frame = bounds
        sdfContainer?.frame = bounds
        // The lens element is the silhouette's straight-sided body: inset by
        // the shoulder radius so its rounded bottom corners coincide exactly
        // with the silhouette's bottom arcs. Its rounded top corners sit
        // under the solid black band and are never visible.
        sdfElement?.frame = bounds.insetBy(
            dx: HangingNotchMetrics.topShoulderRadius, dy: 0
        )
        CATransaction.commit()
    }

    private static func makeGlassFilter() -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let filter = filterClass
                  .perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        // Freshly created filters start from zeroed inputs, not the values a
        // live NSGlassEffectView carries — seed the full system baseline
        // first, then apply our tuning on top.
        for (key, value) in systemClearBaseline {
            filter.setValue(value, forKey: key)
        }
        for (key, value) in NotchGlassStyle.glassFilterOverrides {
            filter.setValue(value, forKey: key)
        }
        return filter
    }

    /// Input values recovered from a live `NSGlassEffectView` in `.clear`
    /// style (240×120, corner radius 20) via keyed-archive inspection.
    private static let systemClearBaseline: [String: Any] = [
        "inputSourceSublayerName": "@0",
        "inputClamp": 1,
        "inputClampPreserveHue": false,
        "inputMaxHeadroom": 9999,
        // Blur: radius with five distance/opacity bands.
        "inputBlurRadius": 10,
        "inputBlurOpacity0": 1, "inputBlurDistance0": 0,
        "inputBlurOpacity1": 1, "inputBlurDistance1": 0,
        "inputBlurOpacity2": 1, "inputBlurDistance2": 0,
        "inputBlurOpacity3": 1, "inputBlurDistance3": 0,
        "inputBlurOpacity4": 1, "inputBlurDistance4": 0,
        // Refraction (the lensing itself).
        "inputInnerRefractionAmount": -60,
        "inputInnerRefractionHeight": 20,
        "inputOuterRefractionAmount": 0,
        "inputOuterRefractionHeight": 0,
        "inputRefractionDistance0": -1,
        "inputRefractionDistance1": -0.5,
        "inputRefractionOpacity": 0,
        // Face wash.
        "inputFaceOpacity": 1,
        "inputFaceColorMatrixBlack": 0.05,
        "inputFaceColorMatrixWhite": 0.8,
        "inputFaceColorMatrixSaturation": 1,
        "inputFaceColorMatrixFillColor": CGColor(red: 1, green: 1, blue: 1, alpha: 0.05),
        // Edge light bleed.
        "inputBleedAmount": 0,
        "inputBleedOpacity": 0,
        "inputBleedHeight": 0,
        "inputBleedBlurRadius": 0,
        "inputBleedDistance0": 1,
        "inputBleedDistance1": 0,
        "inputBleedDarkenBlend": true,
        "inputBleedColorMatrixBlack": 0.75,
        "inputBleedColorMatrixWhite": 1,
        "inputBleedColorMatrixSaturation": 1.2,
        // Contact shadow (disabled by zero opacity in clear style).
        "inputShadowOpacity": 0,
        "inputShadowAmount": 75,
        "inputShadowHeight": 48,
        "inputShadowRadius": 0,
        "inputShadowBlurRadius": 0,
        "inputShadowOffset": NSValue(size: NSSize(width: 0, height: 8)),
        "inputShadowDistanceOffset": 0,
        "inputShadowVibrancyContribution": 0,
        "inputShadowColorMatrixBlack": 0,
        "inputShadowColorMatrixWhite": 1,
        "inputShadowColorMatrixSaturation": 1.2,
        "inputShadowColorMatrixFillColor": CGColor(red: 0, green: 0, blue: 0, alpha: 0.1),
        // SDR/tone-mapping bookkeeping.
        "inputSDRGradientDistance0": 0,
        "inputSDRGradientDistance1": 0,
        "inputSDRShadowOpacity": 0,
        "inputSDRHoldingToneEnabled": false,
        "inputSDRHoldingToneWhite": 1,
    ]
}

/// Fallback backdrop: behind-window blur shaped by the view's own mask image.
/// SwiftUI `.mask`/`.clipShape` cannot clip behind-window blur — the window
/// server composites it outside SwiftUI's render tree — so the mask must live
/// on the `NSVisualEffectView` itself.
private struct NotchVisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // fullScreenUI transmits far more backdrop color than hudWindow; the
        // scrim above supplies whatever darkening legibility still needs.
        view.material = .fullScreenUI
        // The panel never becomes key, so following window state would leave
        // the blur permanently inert.
        view.state = .active
        view.maskImage = Self.silhouetteMask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Stretchable mask: every curve lives inside the cap-inset margins (the
    /// bottom corner arc ends `topShoulderRadius + bottomCornerRadius` points
    /// from each side edge), so resizing during the expand spring stretches
    /// only the flat middle and never regenerates the image.
    private static let silhouetteMask: NSImage = {
        let top = HangingNotchMetrics.topShoulderRadius
        let bottom = HangingNotchMetrics.bottomCornerRadius
        let side = top + bottom
        let size = NSSize(width: side * 2 + 4, height: top + bottom + 4)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(HangingNotchGeometry.path(
                in: rect,
                topShoulderRadius: top,
                bottomCornerRadius: bottom
            ))
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: top, left: side, bottom: bottom, right: side)
        image.resizingMode = .stretch
        return image
    }()
}
