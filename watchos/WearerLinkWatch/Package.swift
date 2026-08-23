// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "WearerLinkWatch",
  platforms: [
    .watchOS(.v7)
  ],
  products: [
    .library(name: "WearerLinkWatch", targets: ["WearerLinkWatch"])
  ],
  targets: [
    .target(name: "WearerLinkWatch")
  ]
)
