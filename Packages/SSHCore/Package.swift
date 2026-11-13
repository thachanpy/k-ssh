// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SSHCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSHCore", targets: ["SSHCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
        // Same sources/ranges Citadel 0.12.1 resolves to; declared directly because Citadel does
        // not re-export NIOSSH/NIOCore (needed for the host-key delegate adapter). See ADR 0001.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // Citadel's key types (Curve25519/Insecure.RSA) come from swift-crypto's `Crypto` module.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "SSHCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SSHCoreTests",
            dependencies: [
                "SSHCore",
                // Tests exercise the shell channel handler offline with EmbeddedChannel.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
