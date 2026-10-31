// swift-tools-version: 5.9
import PackageDescription

// Isolated verification target. The Xcode app still uses its existing project.
let package = Package(
    name: "ExternalInsulinValidation",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ExternalInsulinCore", targets: ["ExternalInsulinCore"])],
    targets: [
        .target(name: "ExternalInsulinCore", path: "FreeAPS/Sources/Modules/ExternalInsulin",
                exclude: ["ExternalInsulinView.swift"],
                sources: ["ExternalInsulinRecord.swift", "InPenRecordDecoder.swift", "ExternalInsulinStore.swift", "InPenBluetoothReader.swift"]),
        .testTarget(name: "ExternalInsulinTests", dependencies: ["ExternalInsulinCore"],
                    path: "Tests/ExternalInsulinTests")
    ]
)
