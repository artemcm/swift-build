//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
import SWBCore
import SWBMacro
import Foundation

@PluginExtensionSystemActor public func initializePlugin(_ manager: PluginManager) {
    let plugin = AndroidPlugin()
    manager.register(AndroidPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(AndroidEnvironmentExtension(plugin: plugin), type: EnvironmentExtensionPoint.self)
    manager.register(AndroidPlatformExtension(), type: PlatformInfoExtensionPoint.self)
    manager.register(AndroidSDKRegistryExtension(plugin: plugin), type: SDKRegistryExtensionPoint.self)
    manager.register(AndroidToolchainRegistryExtension(plugin: plugin), type: ToolchainRegistryExtensionPoint.self)
}

final class AndroidPlugin: Sendable {
    private let androidSDKInstallations = AsyncCache<OperatingSystem, [AndroidSDK]>()

    func cachedAndroidSDKInstallations(host: OperatingSystem) async throws -> [AndroidSDK] {
        try await androidSDKInstallations.value(forKey: host) {
            // Always pass localFS because this will be cached, and executes a process on the host system so there's no reason to pass in any proxy.
            try await AndroidSDK.findInstallations(host: host, fs: localFS)
        }
    }
}

struct AndroidPlatformSpecsExtension: SpecificationsExtension {
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBAndroidPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    func specificationDomains() -> [String : [String]] {
        ["android": ["linux"]]
    }
}

struct AndroidEnvironmentExtension: EnvironmentExtension {
    let plugin: AndroidPlugin

    func additionalEnvironmentVariables(context: any EnvironmentExtensionAdditionalEnvironmentVariablesContext) async throws -> [String: String] {
        switch context.hostOperatingSystem {
        case .windows, .macOS, .linux:
            if let latest = try? await plugin.cachedAndroidSDKInstallations(host: context.hostOperatingSystem).first {
                return [
                    "ANDROID_SDK_ROOT": latest.path.str,
                    "ANDROID_NDK_ROOT": latest.ndkPath?.str,
                ].compactMapValues { $0 }
            }
        default:
            break
        }
        return [:]
    }
}

struct AndroidPlatformExtension: PlatformInfoExtension {
    func additionalPlatforms(context: any PlatformInfoExtensionAdditionalPlatformsContext) throws -> [(path: Path, data: [String: PropertyListItem])] {
        [
            (.root, [
                "Type": .plString("Platform"),
                "Name": .plString("android"),
                "Identifier": .plString("android"),
                "Description": .plString("android"),
                "FamilyName": .plString("Android"),
                "FamilyIdentifier": .plString("android"),
                "IsDeploymentPlatform": .plString("YES"),
            ])
        ]
    }
}

struct AndroidSDKRegistryExtension: SDKRegistryExtension {
    let plugin: AndroidPlugin

    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] {
        let host = context.hostOperatingSystem
        guard let androidPlatform = context.platformRegistry.lookup(name: "android") else {
            return []
        }

        let defaultProperties: [String: PropertyListItem] = [
            "SDK_STAT_CACHE_ENABLE": "NO",

            // Workaround to avoid `-dependency_info` on Linux.
            "LD_DEPENDENCY_INFO_FILE": .plString(""),

            // Android uses lld, not the Apple linker
            // FIXME: Make this option conditional on use of the Apple linker (or perhaps when targeting an Apple triple?)
            "LD_DETERMINISTIC_MODE": "NO",

            "GENERATE_TEXT_BASED_STUBS": "NO",
            "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",

            "CHOWN": "/usr/bin/chown",

            "LIBTOOL": .plString(host.imageFormat.executableName(basename: "llvm-lib")),
            "AR": .plString(host.imageFormat.executableName(basename: "llvm-ar")),
        ]

        guard let androidSdk = try? await plugin.cachedAndroidSDKInstallations(host: host).first else {
            return []
        }

        guard let abis = androidSdk.abis, let deploymentTargetRange = androidSdk.deploymentTargetRange else {
            return []
        }

        let allPossibleTriples = abis.values.flatMap { abi in
            (max(deploymentTargetRange.min, abi.min_os_version)...deploymentTargetRange.max).map { deploymentTarget in
                var triple = abi.llvm_triple
                triple.vendor = "unknown" // Android NDK uses "none", Swift SDKs use "unknown"
                triple.environment += "\(deploymentTarget)"
                return triple
            }
        }.map(\.description)

        let androidSwiftSDKs = (try? SwiftSDK.findSDKs(
            targetTriples: allPossibleTriples,
            fs: context.fs,
            hostOperatingSystem: context.hostOperatingSystem
        )) ?? []

        let swiftSettings: [String: PropertyListItem]
        // FIXME: We need a way to narrow down the list, possibly by passing down a Swift SDK identifier from SwiftPM
        // The resource path should be the same for all triples in an Android Swift SDK
        if let androidSwiftSDK = androidSwiftSDKs.only, let swiftResourceDir = Set(androidSwiftSDK.targetTriples.values.map { tripleProperties in androidSwiftSDK.path.join(tripleProperties.swiftResourcesPath) }).only {
            swiftSettings = [
                "SWIFT_LIBRARY_PATH": .plString(swiftResourceDir.join("android").str),
                "SWIFT_RESOURCE_DIR": .plString(swiftResourceDir.str),
                "SWIFT_TARGET_TRIPLE": .plString("$(CURRENT_ARCH)-unknown-$(SWIFT_PLATFORM_TARGET_PREFIX)$(LLVM_TARGET_TRIPLE_SUFFIX)"),
                "LIBRARY_SEARCH_PATHS": "$(inherited) $(SWIFT_RESOURCE_DIR)/../$(__ANDROID_TRIPLE_$(CURRENT_ARCH))",
            ].merging(abis.map {
                ("__ANDROID_TRIPLE_\($0.value.llvm_triple.arch)", .plString($0.value.triple))
            }, uniquingKeysWith: { _, new in new })
        } else {
            swiftSettings = [:]
        }

        return [(androidSdk.sysroot ?? .root, androidPlatform, [
            "Type": .plString("SDK"),
            "Version": .plString("0.0.0"),
            "CanonicalName": .plString("android"),
            "IsBaseSDK": .plBool(true),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("android"),
            ].merging(defaultProperties, uniquingKeysWith: { _, new in new })),
            "CustomProperties": .plDict([
                // Unlike most platforms, the Android version goes on the environment field rather than the system field
                // FIXME: Make this configurable in a better way so we don't need to push build settings at the SDK definition level
                "LLVM_TARGET_TRIPLE_OS_VERSION": .plString("linux"),
                "LLVM_TARGET_TRIPLE_SUFFIX": .plString("-android$(ANDROID_DEPLOYMENT_TARGET)"),
            ].merging(swiftSettings, uniquingKeysWith: { _, new in new })),
            "SupportedTargets": .plDict([
                "android": .plDict([
                    "Archs": .plArray(abis.map { .plString($0.value.llvm_triple.arch) }),
                    "DeploymentTargetSettingName": .plString("ANDROID_DEPLOYMENT_TARGET"),
                    "DefaultDeploymentTarget": .plString("\(deploymentTargetRange.min)"),
                    "MinimumDeploymentTarget": .plString("\(deploymentTargetRange.min)"),
                    "MaximumDeploymentTarget": .plString("\(deploymentTargetRange.max)"),
                    "LLVMTargetTripleEnvironment": .plString("android"), // FIXME: androideabi for armv7!
                    "LLVMTargetTripleSys": .plString("linux"),
                    "LLVMTargetTripleVendor": .plString("none"),
                ])
            ]),
            "Toolchains": .plArray([
                .plString("android")
            ])
        ])]
    }
}

struct AndroidToolchainRegistryExtension: ToolchainRegistryExtension {
    let plugin: AndroidPlugin

    func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
        guard let toolchainPath = try? await plugin.cachedAndroidSDKInstallations(host: context.hostOperatingSystem).first?.toolchainPath else {
            return []
        }

        return [
            Toolchain(
                identifier: "android",
                displayName: "Android",
                version: Version(0, 0, 0),
                aliases: [],
                path: toolchainPath,
                frameworkPaths: [],
                libraryPaths: [],
                defaultSettings: [:],
                overrideSettings: [:],
                defaultSettingsWhenPrimary: [:],
                executableSearchPaths: [toolchainPath.join("bin")],
                testingLibraryPlatformNames: [],
                fs: context.fs)
        ]
    }
}
