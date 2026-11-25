import Foundation

@_silgen_name("csops")
nonisolated private func csops(
    _ pid: pid_t,
    _ operation: UInt32,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int32

/// The identifier in this process's code signature, as the kernel reports it.
///
/// System services attribute a process to an app by its signature, not by
/// `Info.plist`. A re-signing tool can leave the two different, which is
/// invisible from `Bundle.main`.
nonisolated enum CodeSigningIdentity {
    private static let identityOperation: UInt32 = 11

    static var signingIdentifier: String? {
        // The kernel writes an 8-byte blob header before the string.
        let headerSize = 8
        var buffer = [UInt8](repeating: 0, count: headerSize + 512)
        let status = buffer.withUnsafeMutableBytes {
            csops(getpid(), identityOperation, $0.baseAddress, $0.count)
        }
        guard status == 0 else { return nil }
        let identifier = buffer.dropFirst(headerSize).prefix { $0 != 0 }
        guard !identifier.isEmpty else { return nil }
        return String(decoding: identifier, as: UTF8.self)
    }
}
