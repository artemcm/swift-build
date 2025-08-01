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

import SWBUtil
public import SWBMacro


/// Encapsulates a type of action for a build rule.  Concrete types of actions involve the ability to invoke a build tool or to run a custom shell script.
public protocol BuildRuleAction: AnyObject, CustomStringConvertible, Sendable {
    var inputFileGroupingStrategies: [any InputFileGroupingStrategy] { get }

    /// True if this rule is architecture neutral, i.e. it should only be run once for a file in the Sources build phase, not once for each architecture.
    var isArchitectureNeutral: Bool { get }

    /// If true, then outputs generated by this rule should not be further processed by other tools.
    var dontProcessOutputs: Bool { get }

    /// Whether actions of this type should run during `InstallAPI`.
    var supportsInstallAPI: Bool { get }

    /// Whether actions of this type should run during `InstallHeaders`.
    var supportsInstallHeaders: Bool { get }

    /// True if the presence of actions of this type requires the target to use TAPI.
    var requiresTextBasedAPI: Bool { get }

    /// Identifier of the rule.
    var identifier: String { get }

    /// A textual description of the rule, intended for diagnostic purposes and not as a human-readable display name.
    var description: String { get }

    /// The name of the build rule.
    var name: String { get }
}


/// A build rule action that creates a build task to invoke a build tool.
public final class BuildRuleTaskAction: BuildRuleAction {
    public let toolSpec: CommandLineToolSpec

    public var name: String {
        return toolSpec.name
    }

    @_spi(Testing) public init(toolSpec: CommandLineToolSpec) {
        self.toolSpec = toolSpec
    }

    public var inputFileGroupingStrategies: [any InputFileGroupingStrategy] {
        return toolSpec.inputFileGroupingStrategies ?? []
    }

    public var isArchitectureNeutral: Bool {
        return toolSpec.isArchitectureNeutral
    }

    public var dontProcessOutputs: Bool {
        return toolSpec.dontProcessOutputs
    }

    public var supportsInstallAPI: Bool {
        return toolSpec.supportsInstallAPI
    }

    public var supportsInstallHeaders: Bool {
        return toolSpec.supportsInstallHeaders
    }

    public var requiresTextBasedAPI: Bool {
        return toolSpec.requiresTextBasedAPI
    }

    public var identifier: String {
        return toolSpec.identifier
    }

    public var description: String {
        return "<\(type(of: self)):\(toolSpec.identifier)>"
    }
}


/// A build rule action that creates a build task to run a script.
public final class BuildRuleScriptAction: BuildRuleAction {
    public struct OutputFileInfo: Sendable {
        public let path: MacroStringExpression
        public let additionalCompilerFlags: MacroStringListExpression?
    }
    public let guid: String
    public let name: String
    public let interpreterPath: String
    public let scriptSource: String
    public let inputFiles: [MacroStringExpression]
    public let inputFileLists: [MacroStringExpression]
    public let outputFiles: [OutputFileInfo]
    public let outputFileLists: [MacroStringExpression]
    public let dependencyInfo: DependencyInfoFormat?
    public let runOncePerArchitecture: Bool
    public let runDuringInstallAPI: Bool
    public let runDuringInstallHeaders: Bool

    @_spi(Testing) public init(guid: String, name: String, interpreterPath: String, scriptSource: String, inputFiles: [MacroStringExpression], inputFileLists: [MacroStringExpression], outputFiles: [OutputFileInfo], outputFileLists: [MacroStringExpression], dependencyInfo: DependencyInfoFormat?, runOncePerArchitecture: Bool, runDuringInstallAPI: Bool, runDuringInstallHeaders: Bool) {
        self.guid = guid
        self.name = name
        self.interpreterPath = interpreterPath
        self.scriptSource = scriptSource
        self.inputFiles = inputFiles
        self.inputFileLists = inputFileLists
        self.outputFiles = outputFiles
        self.outputFileLists = outputFileLists
        self.dependencyInfo = dependencyInfo
        self.runOncePerArchitecture = runOncePerArchitecture
        self.runDuringInstallAPI = runDuringInstallAPI
        self.runDuringInstallHeaders = runDuringInstallHeaders
    }

    public var inputFileGroupingStrategies: [any InputFileGroupingStrategy] {
        return []
    }

    public var isArchitectureNeutral: Bool {
        return !runOncePerArchitecture
    }

    public var dontProcessOutputs: Bool {
        return false
    }

    public var supportsInstallAPI: Bool {
        return runDuringInstallAPI
    }

    public var supportsInstallHeaders: Bool {
        return runDuringInstallHeaders
    }

    public var requiresTextBasedAPI: Bool {
        // In general anything that might install symbols for other projects should use TAPI.
        return supportsInstallAPI || supportsInstallHeaders
    }

    public var identifier: String {
        return guid
    }

    public var description: String {
        return "<\(type(of: self)):\(interpreterPath):\(scriptSource)>"
    }
}
