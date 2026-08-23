import CoreText
import Foundation

/// Registers Pour's three bundled variable fonts (Inter, Fraunces, JetBrains Mono —
/// the same families the Brewed AI brand guide specifies for web) so `PourFont` can
/// address them by PostScript name. Call once, before the first view draws.
public enum FontRegistrar {

    public static func registerAll() {
        guard let fontsDirectory = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              FileManager.default.fileExists(atPath: fontsDirectory.path)
        else { return }
        let names = ["Inter-Variable.ttf", "Fraunces-Variable.ttf", "JetBrainsMono-Variable.ttf"]
        for name in names {
            let url = fontsDirectory.appendingPathComponent(name)
            var error: Unmanaged<CFError>?
            // Fails silently (and PourFont falls back to the system font) if a name
            // collides with something already registered — not worth crashing over.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}
