#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import SwiftUI

enum FontRegistration {
    static var familyName = "Inter Variable"

    static let availableFonts: [(label: String, family: String)] = [
        ("Inter", "Inter Variable"),
        ("Avenir Next", "Avenir Next"),
        ("Baskerville", "Baskerville"),
        ("Charter", "Charter"),
        ("DIN Alternate", "DIN Alternate"),
        ("Futura", "Futura"),
        ("Galvji", "Galvji"),
        ("Georgia", "Georgia"),
        ("Gill Sans", "Gill Sans"),
        ("Helvetica Neue", "Helvetica Neue"),
        ("Menlo", "Menlo"),
        ("Monaco", "Monaco"),
        ("Optima", "Optima"),
        ("Palatino", "Palatino"),
        ("SF Mono", "SF Mono"),
    ]

    static func registerFonts() {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.url(forResource: "StockDeck_StockDeck", withExtension: "bundle").flatMap { Bundle(url: $0) }?.resourceURL,
        ]
        for base in candidates.compactMap({ $0 }) {
            let url = base.appendingPathComponent("InterVariable.ttf")
            if FileManager.default.fileExists(atPath: url.path) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                return
            }
        }
        familyName = "Helvetica Neue"
    }

    #if os(macOS)
    static func monospacedDigitsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        let base = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        let tnum = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                kCTFontFeatureTypeIdentifierKey as NSFontDescriptor.AttributeName: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey as NSFontDescriptor.AttributeName: kMonospacedNumbersSelector
            ]]
        ])
        return NSFont(descriptor: tnum, size: size) ?? base
    }
    #else
    static func monospacedDigitsFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        let base = UIFont(descriptor: descriptor, size: size)
        let tnum = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
            ]]
        ])
        return UIFont(descriptor: tnum, size: size)
    }
    #endif
}

extension Font {
    static func inter(_ size: CGFloat, weight: Weight? = nil, relativeTo style: TextStyle = .body) -> Font {
        let font = Font.custom(FontRegistration.familyName, size: size)
        if let weight { return font.weight(weight) }
        return font
    }
}
