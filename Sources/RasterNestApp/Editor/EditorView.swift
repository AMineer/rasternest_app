import AppKit
import RasterNestCore
import RasterNestRender
import SwiftUI

struct EditorActions {
    var copy: () -> Void
    var export: () -> Void
    var save: () -> Void
    var zoomFit: () -> Void
    var zoomActual: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var dragItem: () -> NSItemProvider
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let scrollView: NSScrollView
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            InspectorBar(model: model)
            Divider()
            ScrollViewHost(scrollView: scrollView)
        }
        .tint(Brand.violetColor)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, selected: model.tool == tool) { model.tool = tool }
            }

            Spacer(minLength: 12)

            Group {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)")
                    .disabled(!model.canUndo)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⇧⌘Z)")
                    .disabled(!model.canRedo)
            }
            .buttonStyle(.borderless)
            .id(model.historyVersion)

            Menu("\(model.zoomPercent)%") {
                Button("Zoom to Fit", action: actions.zoomFit)
                Button("Actual Size", action: actions.zoomActual)
                Button("Zoom In", action: actions.zoomIn)
                Button("Zoom Out", action: actions.zoomOut)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 6)

            Divider().frame(height: 20)

            Image(systemName: "hand.draw")
                .font(.system(size: 14))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
                .help("Drag the annotated image into any app")
                .onDrag(actions.dragItem)

            Button(action: actions.copy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy annotated image (⌘C)")

            Button(action: actions.export) {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .help("Export PNG/JPEG (⌘E)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Brand.violetColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
    }
}

private struct InspectorBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            content
            Spacer(minLength: 8)
            Text("\(model.image.width) × \(model.image.height) px")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        if model.tool == .crop {
            Text(model.cropRect == nil ? "Drag over the area to keep." : "Press Return to crop, Esc to cancel.")
                .foregroundStyle(.secondary)
            if model.cropRect != nil {
                Button("Apply Crop") { model.applyCrop() }
                Button("Cancel") { model.cropRect = nil }
            }
        } else if let kind = model.inspectedKind {
            controls(for: kind)
            if model.selectedID != nil {
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete (⌫)")
            }
        } else {
            Text("Click an annotation to edit it, or pick a tool above.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(for kind: AnnotationKind) -> some View {
        let s = model.pixelScale
        switch kind {
        case .pixelate:
            slider("Block", \.lineWidth, 4 * s...40 * s)
        case .spotlight:
            slider("Dim", \.opacity, 0.15...0.9)
        case .highlight:
            ColorSwatches(model: model)
            slider("Opacity", \.opacity, 0.15...0.8)
        case .text:
            ColorSwatches(model: model)
            slider("Size", \.fontSize, 10 * s...96 * s)
            toggle("Callout", \.filled)
            toggle("Shadow", \.shadow)
        case .step:
            ColorSwatches(model: model)
            slider("Size", \.fontSize, 8 * s...48 * s)
            toggle("Shadow", \.shadow)
        case .rectangle, .ellipse:
            ColorSwatches(model: model)
            slider("Width", \.lineWidth, 1 * s...20 * s)
            toggle("Fill", \.filled)
            toggle("Shadow", \.shadow)
        case .arrow, .line, .pen:
            ColorSwatches(model: model)
            slider("Width", \.lineWidth, 1 * s...20 * s)
            toggle("Shadow", \.shadow)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AnnotationStyle, T>, key: String) -> Binding<T> {
        Binding(
            get: { model.inspectedStyle[keyPath: keyPath] },
            set: { value in model.updateInspectedStyle(coalesce: key) { $0[keyPath: keyPath] = value } }
        )
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<AnnotationStyle, CGFloat>,
                        _ range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Slider(value: binding(keyPath, key: label), in: range)
                .frame(width: 110)
                .controlSize(.small)
        }
    }

    private func toggle(_ label: String, _ keyPath: WritableKeyPath<AnnotationStyle, Bool>) -> some View {
        Toggle(label, isOn: binding(keyPath, key: label))
            .toggleStyle(.checkbox)
    }
}

private struct ColorSwatches: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RGBA.palette, id: \.self) { color in
                let selected = model.inspectedStyle.color.withAlpha(1) == color
                Circle()
                    .fill(Color(nsColor: color.nsColor))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .overlay(Circle().stroke(Brand.violetColor, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
                    .onTapGesture { set(color) }
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.inspectedStyle.color.nsColor) },
                set: { set(RGBA(NSColor($0))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 28)
        }
    }

    private func set(_ color: RGBA) {
        model.updateInspectedStyle(coalesce: "color") { $0.color = color }
    }
}

private struct ScrollViewHost: NSViewRepresentable {
    let scrollView: NSScrollView
    func makeNSView(context: Context) -> NSScrollView { scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Keeps the image centred when it is smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
