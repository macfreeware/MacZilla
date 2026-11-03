// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacZilla",
    platforms: [.macOS(.v14)],
    products: [
        // FTP / FTPS / SFTP client library, also used by MacExplorer.
        .library(name: "FTPKit", targets: ["FTPKit"]),
    ],
    targets: [
        .target(name: "FTPKit"),
        .executableTarget(name: "MacZilla", dependencies: ["FTPKit"]),
        .executableTarget(name: "ftpcheck", dependencies: ["FTPKit"]),
    ]
)
