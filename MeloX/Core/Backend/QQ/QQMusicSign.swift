import CryptoKit
import Foundation

/// QQ 音乐客户端请求使用的 `zzc` 签名算法。
///
/// 与 `QQMusicApi/qqmusic_api/algorithms/sign.py` 保持一致：
/// SHA-1 十六进制摘要 → 三段固定下标/异或混淆 → Base64 去特殊字符。
nonisolated enum QQMusicSign {
    private static let part1Indexes = [23, 14, 6, 36, 16, 7, 19]
    private static let part2Indexes = [16, 1, 32, 12, 19, 27, 8, 5]
    private static let scrambleValues: [UInt8] = [
        89, 39, 179, 150, 218, 82, 58, 252, 177, 52,
        186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
    ]

    static func zzcSign(_ payload: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        let characters = Array(hex)

        let part1 = String(part1Indexes.map { characters[$0] })
        let part2 = String(part2Indexes.map { characters[$0] })

        var scrambled = [UInt8](repeating: 0, count: scrambleValues.count)
        for (index, value) in scrambleValues.enumerated() {
            let start = hex.index(hex.startIndex, offsetBy: index * 2)
            let end = hex.index(start, offsetBy: 2)
            let byte = UInt8(hex[start..<end], radix: 16) ?? 0
            scrambled[index] = value ^ byte
        }

        let encoded = Data(scrambled).base64EncodedString()
        let cleaned = encoded.filter {
            $0 != "\\" && $0 != "/" && $0 != "+" && $0 != "="
        }
        return ("zzc" + part1 + cleaned + part2).lowercased()
    }
}
