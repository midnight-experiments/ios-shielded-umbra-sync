// swift-tools-version:5.9
// A macOS command-line check of the iOS app's client code (App/Client, linked into check/): it runs the PIR calls
// against a live server and compares the records with the TypeScript client's (check/read-reference.ts). The app
// itself is built from project.yml (XcodeGen).
import PackageDescription

let package = Package(
    name: "PssClientCheck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "pss-client-check", path: "check",
                          exclude: ["read-reference.ts", "Metal"],
                          swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
    ]
)
