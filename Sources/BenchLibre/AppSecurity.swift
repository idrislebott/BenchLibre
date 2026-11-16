import Foundation
import Security
import Darwin
import BenchCore

/// Public, read-only inspection of our signature. No authorization service,
/// password, helper executable or sandbox exception is involved.
enum AppSecurity {
    private struct Policy: Sendable {
        var valid = false
        var sandbox = false
        var hardened = false
        var unexpected: [String] = []
    }
    private static let policy: Policy = inspect()

    private static func inspect() -> Policy {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber else { return Policy() }
        let identities: Set<String> = ["com.apple.application-identifier", "com.apple.developer.team-identifier"]
        let allowed = identities.union(["com.apple.security.app-sandbox"])
        let unexpected = entitlements.keys.filter { !allowed.contains($0) }.sorted()
        let identityValuesValid = identities.allSatisfy { key in
            guard let value = entitlements[key] else { return true }
            guard let string = value as? String else { return false }
            return !string.isEmpty && string.utf8.count <= 256
        }
        let sandbox = (entitlements["com.apple.security.app-sandbox"] as? Bool) == true
        let hardened = flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
        return Policy(valid: sandbox && hardened && unexpected.isEmpty && identityValuesValid && geteuid() != 0,
                      sandbox: sandbox, hardened: hardened, unexpected: unexpected)
    }

    static func requireSandbox() {
        guard policy.valid else {
            FileHandle.standardError.write(Data("BenchLibre requires App Sandbox, Hardened Runtime and a signature with no additional entitlements. Use the secure macOS Xcode target with a standard user account.\n".utf8))
            exit(78)
        }
    }
    static var diagnostic: [String: String] {
        ["policyAccepted": String(policy.valid), "appSandbox": String(policy.sandbox),
         "hardenedRuntime": String(policy.hardened), "unexpectedEntitlements": policy.unexpected.joined(separator: ","),
         "networkClient": "false", "networkServer": "false", "userSelectedFiles": "false",
         "reportsDirectory": AppStorage.reports.path,
         "exportsDirectory": AppStorage.exports.path, "temporaryDirectory": AppStorage.temporary.path]
    }
}
