//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

import SWBBuildSystem
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBProtocol

import class Foundation.ProcessInfo

@Suite
fileprivate struct CustomTaskBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func outputParsing() async throws {
        try await withTemporaryDirectory { tmpDir in
            let destination: RunDestinationInfo = .host
            let core = try await getCore()
            let toolchain = try #require(core.toolchainRegistry.defaultToolchain)
            let environment = destination.hostRuntimeEnvironment(core)

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("tool.swift"),
                        TestFile("foo.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": try await swiftVersion,
                            "SDKROOT": "$(HOST_PLATFORM)",
                            "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "MACOSX_DEPLOYMENT_TARGET": "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "CoreFoo", type: .dynamicLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["foo.c"])
                        ],
                        customTasks: [
                            TestCustomTask(
                                commandLine: ["$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/tool\(destination == .windows ? ".exe" : "")"],
                                environment: .init(environment),
                                workingDirectory: tmpDir.str,
                                executionDescription: "My Custom Task",
                                inputs: ["$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/tool\(destination == .windows ? ".exe" : "")"],
                                outputs: [Path.root.join("output").str],
                                enableSandboxing: false,
                                preparesForIndexing: false)
                        ],
                        dependencies: ["tool"]
                    ),
                    TestStandardTarget(
                        "tool", type: .hostBuildTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .host)

            try await tester.fs.writeFileContents(tmpDir.join("Sources").join("tool.swift")) { stream in
                stream <<<
                    """
                    @main
                    struct Entry {
                        static func main() {
                            print("warning: this is a warning")
                        }
                    }
                    """
            }

            try await tester.fs.writeFileContents(tmpDir.join("Sources").join("foo.c")) { stream in
                stream <<<
                    """
                    void foo(void) {}
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                results.checkWarning(.contains("this is a warning"))
                results.checkNoDiagnostics()
            }
        }
    }
}
