import SwiftUI

/// Icon buttons: secondary until pointed at, with a soft square so they read as controls without borders.
struct AppIconButtonStyle: ButtonStyle {
    var size: CGFloat = 12

    /// The hit area, which also sets the height of whatever row the button sits in.
    var frame: CGFloat = 22

    /// Keeps the active tab's button highlighted even when not hovered.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        AppIconButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            size: size,
            frame: frame,
            isActive: isActive)
    }
}

private struct AppIconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let size: CGFloat
    let frame: CGFloat
    let isActive: Bool

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }
    @State private var isHovering = false

    var body: some View {
        let lit = isActive || isHovering || isPressed
        let isOn = isActive || isPressed
        label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(lit ? palette.textPrimary : palette.textSecondary)
            .frame(width: frame, height: frame)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                    .fill(isOn ? palette.selection : (isHovering ? palette.hover : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                            .strokeBorder(isOn ? palette.controlBorder : .clear, lineWidth: 1)))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Segments that share the icon buttons' wash, because a stock Picker's material reads as foreign here.
struct AppSegmentStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        AppSegmentBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isActive: isActive)
    }
}

private struct AppSegmentBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isActive: Bool

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }
    @State private var isHovering = false

    var body: some View {
        let lit = isActive || isHovering || isPressed
        let isOn = isActive || isPressed
        label
            .font(.system(size: AppMetrics.secondaryFontSize, weight: .medium))
            .foregroundStyle(lit ? palette.textPrimary : palette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                    .fill(isOn ? palette.selection : (isHovering ? palette.hover : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                            .strokeBorder(isOn ? palette.controlBorder : .clear, lineWidth: 1)))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// The rounded wash behind list rows: selection outranks hover, hover outranks nothing.
struct AppRowBackground: View {
    let isSelected: Bool
    let isHovering: Bool

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    var body: some View {
        RoundedRectangle(cornerRadius: AppMetrics.rowRadius, style: .continuous)
            .fill(isSelected ? palette.selection : (isHovering ? palette.hover : Color.clear))
    }
}

/// A 1pt palette-colored separator, vertical between columns or horizontal between rows.
struct AppDivider: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    init(_ axis: Axis = .horizontal) { self.axis = axis }

    var body: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}
