import AppKit
import Foundation

/// Pine uses CSS colors, including RGB strings and alpha; app-wide menu-bar hex helpers are opaque.
struct PineStyleColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init?(_ source: String) {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = Self.namedColors[value] ?? value
        if named.hasPrefix("#") {
            var digits = String(named.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard (digits.count == 6 || digits.count == 8), let hex = UInt64(digits, radix: 16) else { return nil }
            let rgba = digits.count == 6 ? (hex << 8) | 255 : hex
            red = Double((rgba >> 24) & 255) / 255
            green = Double((rgba >> 16) & 255) / 255
            blue = Double((rgba >> 8) & 255) / 255
            alpha = Double(rgba & 255) / 255
        } else {
            guard (named.hasPrefix("rgb(") || named.hasPrefix("rgba(")), named.hasSuffix(")"),
                  let start = named.firstIndex(of: "(") else { return nil }
            let parts = named[named.index(after: start)..<named.index(before: named.endIndex)]
                .split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func channel(_ text: String, scale: Double) -> Double? {
                let percent = text.hasSuffix("%")
                guard let number = Double(percent ? String(text.dropLast()) : text), number.isFinite else { return nil }
                return min(1, max(0, number / (percent ? 100 : scale)))
            }
            guard let r = channel(parts[0], scale: 255), let g = channel(parts[1], scale: 255),
                  let b = channel(parts[2], scale: 255), let a = channel(parts.count == 4 ? parts[3] : "1", scale: 1) else { return nil }
            red = r; green = g; blue = b; alpha = a
        }
    }

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        red = Double(rgb.redComponent); green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent); alpha = Double(rgb.alphaComponent)
    }

    var nativeColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var opacityPercent: Int { Int((alpha * 100).rounded()) }
    var cssString: String {
        let rgb = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 1 ? rgb : rgb + String(format: "%02X", byte(alpha))
    }
    private func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
    private static let namedColors = ["white": "#FFFFFF", "black": "#000000", "red": "#FF0000",
        "green": "#008000", "lime": "#00FF00", "blue": "#0000FF", "yellow": "#FFFF00", "orange": "#FFA500",
        "aqua": "#00FFFF", "fuchsia": "#FF00FF", "gray": "#808080", "grey": "#808080", "silver": "#C0C0C0",
        "navy": "#000080", "teal": "#008080", "purple": "#800080", "maroon": "#800000", "olive": "#808000",
        "transparent": "#00000000"]
}

/// Prepared once off the UI thread. Plot IDs stay untouched when a friendly label is generated.
struct PineScriptStylePresentation {
    struct Row: Identifiable {
        let id: String
        let title: String
        let style: String
        let colors: [String]
        let lineWidth: Int
        let marker: String
        let position: String
    }
    let plots: [String: CustomPinePlot]
    let primary: [Row]
    let auxiliary: [Row]

    init(plots input: [String: CustomPinePlot]) {
        var normalized: [String: CustomPinePlot] = [:], primary: [Row] = [], auxiliary: [Row] = []
        let ordered = input.sorted { a, b in
            if a.value.sourceOrder != b.value.sourceOrder { return (a.value.sourceOrder ?? .max) < (b.value.sourceOrder ?? .max) }
            return a.key.compare(b.key, options: .numeric) == .orderedAscending
        }
        for (index, entry) in ordered.enumerated() {
            if Task.isCancelled { break }
            var plot = entry.value
            plot.plotID = plot.plotID ?? entry.key
            normalized[plot.id] = plot
            guard ["line", "hline", "shape", "barcolor"].contains(plot.style) else { continue }
            let internalName = plot.title.first == "#" && Int(plot.title.dropFirst()) != nil
            let unnamed = plot.isUnnamed ?? (plot.title.isEmpty || internalName)
            let numbers = plot.points.compactMap(\.value).filter(\.isFinite)
            let level = numbers.first.flatMap { first in numbers.allSatisfy { $0 == first } ? first : nil }
            let isAuxiliary = unnamed && level != nil && ["line", "hline"].contains(plot.style)
            let title: String
            if unnamed, let level, isAuxiliary {
                title = "Mức " + level.formatted(.number.precision(.fractionLength(0...6)))
            } else if unnamed {
                title = (plot.style == "shape" ? "Dấu tín hiệu " : plot.style == "barcolor" ? "Màu nến " : "Đường ") + String(index + 1)
            } else { title = plot.title }
            var seen = Set<String>(), colors: [String] = []
            for color in [plot.color].compactMap({ $0 }) + plot.points.compactMap(\.color) {
                if seen.insert(color).inserted { colors.append(color) }
            }
            let row = Row(id: plot.id, title: title, style: plot.style, colors: colors,
                lineWidth: min(4, max(1, plot.lineWidth ?? 2)),
                marker: (plot.points.first(where: { $0.markerShape != nil })?.markerShape ?? "triangleup").lowercased()
                    .replacingOccurrences(of: "shape_", with: "").replacingOccurrences(of: "_", with: ""),
                position: (plot.points.first(where: { $0.position != nil })?.position ?? "belowbar").lowercased().contains("above") ? "abovebar" : "belowbar")
            if isAuxiliary { auxiliary.append(row) } else { primary.append(row) }
        }
        plots = normalized; self.primary = primary; self.auxiliary = auxiliary
    }
}
