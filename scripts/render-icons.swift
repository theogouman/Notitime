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
    /// Recadre sur le tracé avant de rendre, et conserve ses proportions.
    ///
    /// La silhouette n'occupe que les trois quarts de la hauteur de son viewBox :
    /// rendue telle quelle dans un carré, elle paraît petite et flotte au milieu
    /// de la barre de menus. On mesure donc son étendue réelle plutôt que de la
    /// deviner, pour que la hauteur demandée soit celle du dessin.
    let cropsToArtwork: Bool

    init(source: String, destination: String, points: Double, scale: Int,
         inset: Double, cropsToArtwork: Bool = false) {
        self.source = source
        self.destination = destination
        self.points = points
        self.scale = scale
        self.inset = inset
        self.cropsToArtwork = cropsToArtwork
    }
}

/// Étendue réelle du dessin dans l'image, en fraction de ses côtés.
///
/// Mesurée sur les pixels opaques d'un rendu de contrôle : c'est plus sûr que
/// d'interpréter le tracé, et cela suit automatiquement un SVG remplacé.
func artworkBounds(of image: NSImage, samples: Int = 512) -> CGRect {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: samples, pixelsHigh: samples,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else {
        return CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: samples, height: samples))
    NSGraphicsContext.restoreGraphicsState()

    var minX = samples, minY = samples, maxX = -1, maxY = -1
    for y in 0..<samples {
        for x in 0..<samples {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    let side = Double(samples)
    // `colorAt` compte les lignes depuis le haut, comme le SVG.
    return CGRect(x: Double(minX) / side, y: Double(minY) / side,
                  width: Double(maxX - minX + 1) / side, height: Double(maxY - minY + 1) / side)
}

func render(_ job: Rendering) throws {
    guard let image = NSImage(contentsOfFile: job.source) else {
        throw NSError(domain: "render", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "SVG illisible : \(job.source)"])
    }
    let bounds = job.cropsToArtwork ? artworkBounds(of: image)
                                    : CGRect(x: 0, y: 0, width: 1, height: 1)
    // Hauteur demandée, largeur déduite des proportions du dessin.
    let aspect = bounds.width / bounds.height
    let pointsHigh = job.points
    let pointsWide = job.points * aspect
    let pixels = Int((pointsWide * Double(job.scale)).rounded())
    let pixelsHigh = Int((pointsHigh * Double(job.scale)).rounded())
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels, pixelsHigh: pixelsHigh,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else {
        throw NSError(domain: "render", code: 2)
    }
    bitmap.size = NSSize(width: pointsWide, height: pointsHigh)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Le dessin complet est agrandi jusqu'à ce que son étendue réelle remplisse
    // le canevas, puis décalé pour l'y amener. Sans recadrage, `bounds` vaut le
    // carré entier et le calcul se réduit à un simple ajustement.
    let insetWidth = pointsWide * (1 - 2 * job.inset)
    let insetHeight = pointsHigh * (1 - 2 * job.inset)
    let drawnWidth = insetWidth / bounds.width
    let drawnHeight = insetHeight / bounds.height
    let originX = pointsWide * job.inset - bounds.minX * drawnWidth
    // L'axe vertical d'AppKit part du bas : l'étendue mesurée depuis le haut se
    // retourne ici, faute de quoi le dessin sortirait du cadre.
    let originY = pointsHigh * job.inset
        - (1 - bounds.minY - bounds.height) * drawnHeight
    image.draw(in: NSRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 3)
    }
    try data.write(to: URL(fileURLWithPath: job.destination))
    print("  \(job.destination) — \(pixels)×\(pixelsHigh)")
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
// La barre de menus mesure 24 pt : 20 pt de dessin la remplissent franchement
// sans toucher les bords. La hauteur porte sur la silhouette elle-même, d'où le
// recadrage — sinon un quart de la hauteur serait du vide.
let menuBarHeight = 20.0
for scale in [1, 2] {
    let suffix = scale == 1 ? "" : "@2x"
    jobs.append(Rendering(source: template,
                          destination: "\(menuBar)/menubar\(suffix).png",
                          points: menuBarHeight, scale: scale, inset: 0.02,
                          cropsToArtwork: true))
}

print("Rendu des icônes :")
for job in jobs { try render(job) }
print("Terminé — \(jobs.count) fichiers.")
