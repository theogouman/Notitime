// swift-tools-version:5.10
import PackageDescription

// NotitimeCore porte toute la logique métier testable sans interface ni réseau
// (principes VI et VII de la constitution). Aucune dépendance externe : le
// principe I l'interdit sauf justification écrite dans le plan, et il n'y en a pas.
let package = Package(
    name: "NotitimeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotitimeCore", targets: ["NotitimeCore"])
    ],
    targets: [
        .target(name: "NotitimeCore"),
        .testTarget(
            name: "NotitimeCoreTests",
            dependencies: ["NotitimeCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
