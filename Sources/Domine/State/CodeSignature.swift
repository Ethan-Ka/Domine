import Foundation
import Security

/// The running app's code signing identity. TCC ties a grant to the app's
/// designated requirement, so when this changes (ad-hoc rebuild, a different
/// certificate or team) earlier grants no longer apply to this binary.
enum CodeSignature {
    /// The designated requirement as text. With a certificate it names the
    /// bundle ID and the leaf certificate, so it stays the same across
    /// rebuilds; an ad-hoc signature's requirement is its cdhash, which
    /// changes on every build. nil when the signature cannot be read.
    static var designatedRequirement: String? {
        guard let code = selfStaticCode() else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// Team identifier, or nil for an ad-hoc signature. For the log.
    static var teamIdentifier: String? {
        guard let code = selfStaticCode() else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func selfStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }
}
