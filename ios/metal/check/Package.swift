// swift-tools-version:5.9
// The Metal scan's check (macOS): runs ../MetalScanner.swift (linked as Sources/PssMetal/MetalScanner.swift) with
// ../generated/PssScan.metal compiled at run time, and compares every output with the CPU kernel's
// (make-reference.ts). See ../README.md.
import PackageDescription

let package = Package(
    name: "PssMetalCheck",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PssMetal", targets: ["PssMetal"])],
    targets: [
        .target(name: "PssMetal", path: "Sources/PssMetal"),
        .executableTarget(name: "pss-metal-check", dependencies: ["PssMetal"], path: "Sources/pss-metal-check"),
    ]
)
