import AppKit
import RasterNestCore
import RasterNestRender
import SwiftUI

/// Popover for the capture's frame: padding, background, corners, shadow, border.
struct FrameControls: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared

    private var s: CGFloat { model.pixelScale }

    private struct Preset: Identifiable {
        let id: String
        let make: (CGFloat) -> CanvasEffects
    }

    private let presets: [Preset] = [
        Preset(id: "None") { _ in .none },
        Preset(id: "Docs") { CanvasEffects.documentation(scale: $0) },
        Preset(id: "Light") { s in
            CanvasEffects(padding: 24 * s, background: .solid, backgroundColor: RGBA(0.973, 0.980, 0.988),
                          cornerRadius: 8 * s, shadow: true)
        },
        Preset(id: "Dark") { s in
            CanvasEffects(padding: 24 * s, background: .solid, backgroundColor: RGBA(0.043, 0.063, 0.125),
                          cornerRadius: 8 * s, shadow: true)
        },
        Preset(id: "Brand") { s in
            CanvasEffects(padding: 40 * s, background: .gradient, backgroundColor: RGBA(0.486, 0.227, 0.929),
                          backgroundColor2: RGBA(0.055, 0.647, 0.914), cornerRadius: 12 * s, shadow: true)
        },
        Preset(id: "Outline") { s in
            CanvasEffects(padding: 0, cornerRadius: 6 * s, borderWidth: 1.5 * s, borderColor: RGBA(0.796, 0.835, 0.882))
        },
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Frame").font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets) { preset in
                    Button(preset.id) {
                        model.updateEffects(coalesce: "preset") { $0 = preset.make(s) }
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            slider("Padding", \.padding, 0...120)
            HStack {
                Text("Background").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: binding(\.background, key: "bg")) {
                    Text("None").tag(CanvasEffects.Background.none)
                    Text("Solid").tag(CanvasEffects.Background.solid)
                    Text("Gradient").tag(CanvasEffects.Background.gradient)
                }
                .labelsHidden()
                .fixedSize()
                if model.effects.background != .none {
                    colorWell(\.backgroundColor, key: "bg1")
                }
                if model.effects.background == .gradient {
                    colorWell(\.backgroundColor2, key: "bg2")
                }
            }
            .disabled(model.effects.padding == 0)
            slider("Corners", \.cornerRadius, 0...32)
            Toggle("Drop shadow", isOn: binding(\.shadow, key: "shadow"))
            HStack {
                slider("Border", \.borderWidth, 0...8)
                colorWell(\.borderColor, key: "border")
            }

            Divider()

            HStack {
                Button("Use for New Captures") {
                    var e = model.effects
                    e.padding /= s
                    e.cornerRadius /= s
                    e.borderWidth /= s
                    settings.defaultFrame = e.isEmpty ? nil : e
                    HUD.show(e.isEmpty ? "New captures won't have a frame" : "New captures will use this frame",
                             symbol: "photo.artframe")
                }
                if settings.defaultFrame != nil {
                    Button("Clear Default") { settings.defaultFrame = nil }
                }
            }
            .controlSize(.small)
            Text(settings.defaultFrame == nil ? "New captures start without a frame." : "New captures start with your saved frame.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .tint(Brand.violetColor)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CanvasEffects, T>, key: String) -> Binding<T> {
        Binding(get: { model.effects[keyPath: keyPath] },
                set: { value in model.updateEffects(coalesce: key) { $0[keyPath: keyPath] = value } })
    }

    /// Sliders show points; the model stores pixels.
    private func slider(_ label: String, _ keyPath: WritableKeyPath<CanvasEffects, CGFloat>,
                        _ range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { model.effects[keyPath: keyPath] / s },
                                  set: { v in model.updateEffects(coalesce: label) { $0[keyPath: keyPath] = (v * s).rounded() } }),
                   in: range)
            Text("\(Int((model.effects[keyPath: keyPath] / s).rounded()))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    private func colorWell(_ keyPath: WritableKeyPath<CanvasEffects, RGBA>, key: String) -> some View {
        ColorPicker("", selection: Binding(
            get: { Color(nsColor: model.effects[keyPath: keyPath].nsColor) },
            set: { c in model.updateEffects(coalesce: key) { $0[keyPath: keyPath] = RGBA(NSColor(c)) } }
        ), supportsOpacity: false)
        .labelsHidden()
        .frame(width: 28)
    }
}
