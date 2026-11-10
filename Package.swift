// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FoamMaster",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FoamMaster",
            path: "Sources/FoamMaster",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
