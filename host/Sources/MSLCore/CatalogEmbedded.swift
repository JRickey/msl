import Foundation

/// Embedded distro catalog data: artifact/icon URLs, pinned hashes, and the
/// known-distro icon table. Logic lives in Catalog.swift.
extension Catalog {
    private static let ubuntuURL =
        "https://cloud-images.ubuntu.com/releases/noble/release-20260615/"
        + "ubuntu-24.04-server-cloudimg-arm64-root.tar.xz"

    private static let debianURL =
        "https://salsa.debian.org/debian/WSL/-/jobs/9606244/artifacts/raw/"
        + "Debian_WSL_ARM64_v1.26.0.0.wsl"

    private static let fedoraURL =
        "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Container/"
        + "aarch64/images/Fedora-WSL-Base-44-1.7.aarch64.wsl"

    private static let openSUSEURL =
        "https://github.com/openSUSE/WSL-instarball/releases/download/v20260423.0/"
        + "openSUSE-Tumbleweed-20260422.aarch64-3.82-Build3.82.wsl"

    private static let kaliURL =
        "https://kali.download/wsl-images/kali-2026.2/"
        + "kali-linux-2026.2-wsl-rootfs-arm64.wsl"

    private static let almaLinuxURL =
        "https://github.com/AlmaLinux/wsl-images/releases/download/v10.2.20260526.0/"
        + "AlmaLinux-10.2_ARM64_20260526.0.wsl"

    private static let ubuntuWhiteIcon = "https://cdn.simpleicons.org/ubuntu/FFFFFF"
    private static let debianWhiteIcon = "https://cdn.simpleicons.org/debian/FFFFFF"
    private static let fedoraWhiteIcon = "https://cdn.simpleicons.org/fedora/FFFFFF"
    private static let openSUSEWhiteIcon = "https://cdn.simpleicons.org/opensuse/FFFFFF"
    private static let kaliWhiteIcon = "https://cdn.simpleicons.org/kalilinux/FFFFFF"
    private static let almaLinuxWhiteIcon = "https://cdn.simpleicons.org/almalinux/FFFFFF"

    static let embeddedJSON = """
        {
          "schema": 1,
          "generatedAt": "2026-07-07T00:00:00Z",
          "families": [
            {
              "name": "ubuntu",
              "friendlyName": "Ubuntu",
              "defaultVersion": "24.04",
              "aliases": [],
              "versions": [
                {
                  "version": "24.04",
                  "aliases": ["noble", "lts"],
                  "status": "recommended",
                  "artifact": {
                    "arch": "arm64",
                    "kind": "rootfsTar",
                    "compression": "xz",
                    "url": "\(ubuntuURL)",
                    "sha256": "15188696da114a3ffd3d3554f5858a0c3ac257933656e85feb4e0e83ad542b4a",
                    "sizeBytes": 214867024
                  },
                  "icon": {
                    "kind": "svg",
                    "url": "\(ubuntuWhiteIcon)",
                    "sha256": "816d06168f4d1fc1dbd07402f6efd09cd2a84ba4dece718045c6d45e2b5cbf68",
                    "sizeBytes": 963,
                    "backgroundHex": "E95420"
                  },
                  "defaultUser": null,
                  "imageSizeGiB": 8,
                  "notes": "Ubuntu 24.04 LTS arm64 cloud rootfs."
                }
              ]
            },
            {
              "name": "almalinux",
              "friendlyName": "AlmaLinux",
              "defaultVersion": "10.2",
              "aliases": ["alma"],
              "versions": [
                {
                  "version": "10.2",
                  "aliases": ["10", "os10"],
                  "status": "experimental",
                  "artifact": {
                    "arch": "arm64",
                    "kind": "rootfsTar",
                    "compression": "gzip",
                    "url": "\(almaLinuxURL)",
                    "sha256": "d3b3ecc7b58ee3cceaa656de04175e81df2e7969efb2e22aba95c9ff1f430949",
                    "sizeBytes": 115300954
                  },
                  "icon": {
                    "kind": "svg",
                    "url": "\(almaLinuxWhiteIcon)",
                    "sha256": "9d2447800654b8aef31c99386d79201c08fa36ea8202bf6337e628a65d764912",
                    "sizeBytes": 3069,
                    "backgroundHex": "000000"
                  },
                  "defaultUser": null,
                  "imageSizeGiB": 8,
                  "notes": "AlmaLinux 10.2 arm64 WSL rootfs."
                }
              ]
            },
            {
              "name": "debian",
              "friendlyName": "Debian GNU/Linux",
              "defaultVersion": "13",
              "aliases": [],
              "versions": [
                {
                  "version": "13",
                  "aliases": ["trixie", "stable"],
                  "status": "experimental",
                  "artifact": {
                    "arch": "arm64",
                    "kind": "rootfsTar",
                    "compression": "gzip",
                    "url": "\(debianURL)",
                    "sha256": "09120df4fadc36fb2a0f7298e197785e6f599f12aaf95d43cba07a8ac7fb316b",
                    "sizeBytes": 89116960
                  },
                  "icon": {
                    "kind": "svg",
                    "url": "\(debianWhiteIcon)",
                    "sha256": "776f50ad816fc8056e2843a6c5e0a640be4fea44443e238e3fbdfea9f68b8ebb",
                    "sizeBytes": 2817,
                    "backgroundHex": "A81D33"
                  },
                  "defaultUser": null,
                  "imageSizeGiB": 8,
                  "notes": "Debian GNU/Linux 13 arm64 WSL rootfs."
                }
              ]
            },
            {
              "name": "fedora",
              "friendlyName": "Fedora",
              "defaultVersion": "44",
              "aliases": ["fedoralinux"],
              "versions": [
                {
                  "version": "44",
                  "aliases": [],
                  "status": "experimental",
                  "artifact": {
                    "arch": "arm64",
                    "kind": "rootfsTar",
                    "compression": "gzip",
                    "url": "\(fedoraURL)",
                    "sha256": "1a3220262dc918b07d08410278205fb35e92c28a53455382028eea1a980476ee",
                    "sizeBytes": 148781265
                  },
                  "icon": {
                    "kind": "svg",
                    "url": "\(fedoraWhiteIcon)",
                    "sha256": "008a3f560b198437059aa143bb366e7d87123a528e314f49a3e6db0bd17c9390",
                    "sizeBytes": 911,
                    "backgroundHex": "51A2DA"
                  },
                  "defaultUser": null,
                  "imageSizeGiB": 8,
                  "notes": "Fedora Linux 44 arm64 WSL rootfs."
                }
              ]
            },
            {
              "name": "kali",
              "friendlyName": "Kali Linux",
              "defaultVersion": "2026.2",
              "aliases": ["kali-linux", "kalilinux"],
              "versions": [
                {
                  "version": "2026.2",
                  "aliases": ["rolling"],
                  "status": "experimental",
                  "artifact": {
                    "arch": "arm64",
                    "kind": "rootfsTar",
                    "compression": "gzip",
                    "url": "\(kaliURL)",
                    "sha256": "0ebc7b7ed93b20ed787b27e217e408179f6b816be505e56dd0db65ce5e73f5f0",
                    "sizeBytes": 245781463
                  },
                  "icon": {
                    "kind": "svg",
                    "url": "\(kaliWhiteIcon)",
                    "sha256": "373bfda86ffb5d2fd505d70a897d406c1545010a68dfc2276669656a00707498",
                    "sizeBytes": 1436,
                    "backgroundHex": "557C94"
                  },
                  "defaultUser": null,
                  "imageSizeGiB": 8,
                  "notes": "Kali Linux 2026.2 arm64 WSL rootfs."
                }
              ]
            },
            {
              "name": "opensuse",
              "friendlyName": "openSUSE Tumbleweed",
              "defaultVersion": "tumbleweed",
              "aliases": ["opensuse-tumbleweed", "suse"],
              "versions": [
                {
                  "version": "tumbleweed",
                  "aliases": ["20260422"],
                  "status": "experimental",
                  "artifact": {
                    "arch": "arm64",
                    "kind": "rootfsTar",
                    "compression": "xz",
                    "url": "\(openSUSEURL)",
                    "sha256": "70d02e702b7788c494ad785bc3987ac1361f263af99d2c8180aac269cf0a9747",
                    "sizeBytes": 53526668
                  },
                  "icon": {
                    "kind": "svg",
                    "url": "\(openSUSEWhiteIcon)",
                    "sha256": "ba0523663305245e2824f0d63fa3256afa7556eb86c4816e9bcfca2f93d1ad6b",
                    "sizeBytes": 1327,
                    "backgroundHex": "73BA25"
                  },
                  "defaultUser": null,
                  "imageSizeGiB": 8,
                  "notes": "openSUSE Tumbleweed arm64 WSL rootfs."
                }
              ]
            }
          ]
        }
        """
}

public struct DistroIconRecord: Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let aliases: [String]
    public let icon: CatalogIcon
}

public enum DistroIconCatalog {
    public static func displayName(for name: String) -> String? {
        return records.first { record in
            record.name == name || record.aliases.contains(name)
        }?.displayName
    }

    public static func icon(for name: String) -> CatalogIcon? {
        return records.first { record in
            record.name == name || record.aliases.contains(name)
        }?.icon
    }

    public static let records: [DistroIconRecord] = [
        DistroIconRecord(
            name: "ubuntu", displayName: "Ubuntu", aliases: [],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/ubuntu/FFFFFF",
                sha256: "816d06168f4d1fc1dbd07402f6efd09cd2a84ba4dece718045c6d45e2b5cbf68",
                sizeBytes: 963, backgroundHex: "E95420")),
        DistroIconRecord(
            name: "almalinux", displayName: "AlmaLinux", aliases: ["alma"],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/almalinux/FFFFFF",
                sha256: "9d2447800654b8aef31c99386d79201c08fa36ea8202bf6337e628a65d764912",
                sizeBytes: 3069, backgroundHex: "000000")),
        DistroIconRecord(
            name: "arch", displayName: "Arch Linux", aliases: ["archlinux"],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/archlinux",
                sha256: "1d45fa365b8308aa408565a649e6646232d43e4ccbc02b106021b8b2dcd65a4d",
                sizeBytes: 780)),
        DistroIconRecord(
            name: "debian", displayName: "Debian GNU/Linux", aliases: [],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/debian/FFFFFF",
                sha256: "776f50ad816fc8056e2843a6c5e0a640be4fea44443e238e3fbdfea9f68b8ebb",
                sizeBytes: 2817, backgroundHex: "A81D33")),
        DistroIconRecord(
            name: "fedora", displayName: "Fedora", aliases: [],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/fedora/FFFFFF",
                sha256: "008a3f560b198437059aa143bb366e7d87123a528e314f49a3e6db0bd17c9390",
                sizeBytes: 911, backgroundHex: "51A2DA")),
        DistroIconRecord(
            name: "kali", displayName: "Kali Linux", aliases: ["kali-linux", "kalilinux"],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/kalilinux/FFFFFF",
                sha256: "373bfda86ffb5d2fd505d70a897d406c1545010a68dfc2276669656a00707498",
                sizeBytes: 1436, backgroundHex: "557C94")),
        DistroIconRecord(
            name: "linuxmint", displayName: "Linux Mint", aliases: ["mint"],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/linuxmint/FFFFFF",
                sha256: "9b8619cda8d53c80fba5c38cbdd533adbc7f1d4c64fd68cc27a998e69f1773d7",
                sizeBytes: 703, backgroundHex: "86BE43")),
        DistroIconRecord(
            name: "opensuse", displayName: "openSUSE", aliases: ["opensuse-tumbleweed", "suse"],
            icon: CatalogIcon(
                kind: .svg, url: "https://cdn.simpleicons.org/opensuse/FFFFFF",
                sha256: "ba0523663305245e2824f0d63fa3256afa7556eb86c4816e9bcfca2f93d1ad6b",
                sizeBytes: 1327, backgroundHex: "73BA25")),
    ]
}
