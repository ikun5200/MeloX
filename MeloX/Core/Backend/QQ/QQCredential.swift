import CryptoKit
import Foundation

/// QQ 音乐登录凭证。
///
/// 字段与 `QQMusicApi/qqmusic_api/models/request.py` 的 `Credential` 对齐，
/// 但使用 Swift 的 camelCase 命名。凭证按当前产品选择以明文 JSON 保存。
nonisolated struct QQCredential: Codable, Equatable, Sendable {
    var musicID: Int = 0
    var musicKey: String = ""
    var refreshKey: String = ""
    var refreshToken: String = ""
    var openID: String = ""
    var accessToken: String = ""
    var encryptUIN: String = ""
    var loginType: Int = 0
    var expiredAt: Int = 0
    var musicKeyCreateTime: Int = 0
    var keyExpiresIn: Int = 0
    var nickName: String = ""
    var avatarURL: String = ""

    enum CodingKeys: String, CodingKey {
        case musicID = "musicid"
        case musicKey = "musickey"
        case refreshKey = "refresh_key"
        case refreshToken = "refresh_token"
        case openID = "openid"
        case accessToken = "access_token"
        case encryptUIN = "encryptUin"
        case loginType = "loginType"
        case expiredAt = "expired_at"
        case musicKeyCreateTime = "musickeyCreateTime"
        case keyExpiresIn = "keyExpiresIn"
        case nickName = "nickName"
        case avatarURL = "avatarURL"
    }

    static let empty = QQCredential()

    var isValid: Bool {
        musicID > 0 && !musicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isExpired: Bool {
        guard musicKeyCreateTime > 0, keyExpiresIn > 0 else {
            return false
        }
        return Int(Date().timeIntervalSince1970)
            >= musicKeyCreateTime + keyExpiresIn
    }

    /// 账号级缓存作用域。用于替代旧实现里的 `SHA256(cookie)`。
    var accountScopeID: String {
        guard isValid else { return "" }
        let material = "\(musicID):\(musicKey)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var maskedMusicKey: String {
        guard musicKey.count > 8 else { return musicKey.isEmpty ? "" : "••••" }
        return "\(musicKey.prefix(4))••••\(musicKey.suffix(4))"
    }

    mutating func clear() {
        self = .empty
    }
}
