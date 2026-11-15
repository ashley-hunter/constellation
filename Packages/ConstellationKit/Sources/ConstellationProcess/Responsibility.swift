import Darwin
import Foundation
import Security
import Synchronization

/// macOS attributes a child's privacy-protected file access (Documents, Downloads, Desktop) to the
/// "responsible" process, which is normally the app that spawned it. A provider spawned with
/// responsibility disclaimed is responsible for itself, as terminal apps arrange for debuggees, so
/// any prompt names the provider and its grant doesn't depend on Constellation's signature.
///
/// The call lives in libsystem_secinit and is not in the public headers, so it is looked up at run
/// time. Where it is missing, children are spawned as before.
///
/// Platform binaries (`/bin/zsh`, `/usr/bin/git`) are never disclaimed: macOS can't prompt for
/// them, so on their own they are silently refused (EPERM) in Documents and the like.
enum Responsibility {
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private nonisolated(unsafe) static let handle = dlopen(nil, RTLD_NOW)

    private static let setDisclaim: SetDisclaim? = dlsym(handle, "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: SetDisclaim.self) }

    private static let responsiblePID: ResponsiblePID? = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsiblePID.self) }

    private static let platformBinaries = Mutex<[String: Bool]>([:])

    /// Marks a spawn of `executable` so the new process is responsible for itself. Returns false
    /// when the call is unavailable or `executable` is a platform binary.
    @discardableResult
    static func disclaim(_ attributes: inout posix_spawnattr_t?, executable: URL) -> Bool {
        guard let setDisclaim, !isPlatformBinary(executable) else { return false }
        return setDisclaim(&attributes, 1) == 0
    }

    /// The process macOS holds responsible for `pid`, or nil when that can't be asked.
    static func responsibleProcess(for pid: pid_t) -> pid_t? {
        guard let responsiblePID else { return nil }
        let responsible = responsiblePID(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Signed as part of macOS itself. Reads the signature without validating it, and caches.
    static func isPlatformBinary(_ executable: URL) -> Bool {
        let path = executable.resolvingSymlinksInPath().path(percentEncoded: false)
        if let known = platformBinaries.withLock({ $0[path] }) { return known }
        var code: SecStaticCode?
        var info: CFDictionary?
        if SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &code) == errSecSuccess, let code {
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        let platform = ((info as? [String: Any])?[kSecCodeInfoPlatformIdentifier as String] as? Int ?? 0) != 0
        platformBinaries.withLock { $0[path] = platform }
        return platform
    }
}
