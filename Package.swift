// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacZilla",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FTPKit"),
        .executableTarget(name: "MacZilla", dependencies: ["FTPKit"]),
        .executableTarget(name: "ftpcheck", dependencies: ["FTPKit"]),
    ]
)
