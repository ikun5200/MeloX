import Foundation

nonisolated struct QQComment: Sendable {
    let id: Int64
    let nickname: String
    let avatarURL: String?
    let content: String
    let publishedAt: Int
    let likedCount: Int
    let isLiked: Bool
    let replyCount: Int
}

nonisolated struct QQCommentPage: Sendable {
    let comments: [QQComment]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int
}
