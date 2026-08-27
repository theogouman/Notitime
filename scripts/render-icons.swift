#!/usr/bin/env swift
import AppKit

// Rend les PNG du catalogue d'assets à partir des SVG de `Design/`.
//
// Aucun outil externe : `NSImage` lit le SVG nativement depuis macOS 13, ce qui
// évite d'imposer librsvg ou Inkscape à quiconque construit le projet.
// Les PNG sont commités — le catalogue doit rester constructible sans ce script.

struct Rendering {
    let source: String
    let destination: String
    let points: Double
    let scale: Int
    /// Marge intérieure, en fraction de la largeur. L'icône de la barre de menus
    /// doit respirer ; celle du Dock porte déjà son propre fond.
    let inset: Double
}

func render(_ job: Rendering) throws {
    guard let image = NSImage(contentsOfFile: job.source) else {
        throw NSError(domain: "render", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "SVG illisible : \(job.source)"])
    }
    let pixels = Int((job.points * Double(job.scale)).rounded())
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else {
        throw NSError(domain: "render", code: 2)
    }
    bitmap.size = NSSize(width: job.points, height: job.points)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let margin = job.points * job.inset
    image.draw(in: NSRect(x: margin, y: margin,
                          width: job.points - 2 * margin, height: job.points - 2 * margin),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 3)
    }
    try data.write(to: URL(fileURLWithPath: job.destination))
    print("  \(job.destination) — \(pixels)×\(pixels)")
}

let root = FileManager.default.currentDirectoryPath
let icon = "\(root)/Design/notitime-icon.svg"
let template = "\(root)/Design/notitime-template.svg"
let appIcon = "\(root)/App/Resources/Assets.xcassets/AppIcon.appiconset"
let menuBar = "\(root)/App/Resources/Assets.xcassets/MenuBarIcon.imageset"

/// Grille macOS : sur un canevas de 1024, le corps de l'icône occupe 824, le
/// reste étant la marge et l'ombre portée. Le SVG fourni dessine son fond arrondi
/// bord à bord — convention iOS. Rendu tel quel, Notitime paraîtrait plus gros
/// que ses voisines dans le Dock. Mettre `0` ici rétablit le cadrage d'origine.
let macOSGridInset = (1024.0 - 824.0) / 2 / 1024.0

// Les cinq tailles du ladder macOS, en 1× et 2×.
let appSizes: [Double] = [16, 32, 128, 256, 512]
var jobs: [Rendering] = []
for size in appSizes {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        jobs.append(Rendering(source: icon,
                              destination: "\(appIcon)/icon_\(Int(size))x\(Int(size))\(suffix).png",
                              points: size, scale: scale, inset: macOSGridInset))
    }
}
// La barre de menus travaille en points : 18 pt de haut, comme les gabarits
// système, en 1× et 2×. La marge évite que la silhouette touche les bords.
for scale in [1, 2] {
    let suffix = scale == 1 ? "" : "@2x"
    jobs.append(Rendering(source: template,
                          destination: "\(menuBar)/menubar\(suffix).png",
                          points: 18, scale: scale, inset: 0.06))
}

print("Rendu des icônes :")
for job in jobs { try render(job) }
print("Terminé — \(jobs.count) fichiers.")
