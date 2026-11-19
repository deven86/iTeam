import Foundation
import SwiftData

// MARK: - Views (free): short posts and 24-hour status
//
// A post is sent, end-to-end encrypted, into each chat its author picked as the audience (direct chats and
// groups). Likes and comments travel back through the same chat, so only that audience ever sees them.

enum PostKind: String, CaseIterable, Identifiable, Codable {
    case moment, achievement, taskDone, recovery, training
    var id: String { rawValue }
    var title: String {
        switch self {
        case .moment: "Moment"
        case .achievement: "Achievement"
        case .taskDone: "Task completed"
        case .recovery: "Recovery"
        case .training: "Training"
        }
    }
    var icon: String {
        switch self {
        case .moment: "camera.fill"
        case .achievement: "trophy.fill"
        case .taskDone: "checkmark.seal.fill"
        case .recovery: "heart.circle.fill"
        case .training: "dumbbell.fill"
        }
    }
}

@Model final class Post {
    @Attribute(.unique) var id: String
    var author: String
    var kind: String = PostKind.moment.rawValue
    var text: String = ""
    var mediaData: Data?
    var isStatus: Bool = false
    var expiresAt: Date?
    var createdAt: Date = Date.now
    var deleted: Bool = false
    /// Chats this post arrived in (or was sent to, for my own posts).
    var convIDsData: Data?

    init(id: String, author: String) { self.id = id; self.author = author }

    var postKind: PostKind { PostKind(rawValue: kind) ?? .moment }
    var media: [AttachmentRef] {
        get { Packed.decode([AttachmentRef].self, mediaData) ?? [] }
        set { mediaData = newValue.isEmpty ? nil : Packed.encode(newValue) }
    }
    var convIDs: [String] {
        get { Packed.decode([String].self, convIDsData) ?? [] }
        set { convIDsData = Packed.encode(newValue) }
    }
    var isLive: Bool { !deleted && (expiresAt.map { $0 > .now } ?? true) }
}

@Model final class PostReaction {
    /// postID|userID
    @Attribute(.unique) var id: String
    var postID: String
    var user: String
    var emoji: String
    var at: Date
    init(postID: String, user: String, emoji: String, at: Date) {
        self.id = postID + "|" + user; self.postID = postID; self.user = user; self.emoji = emoji; self.at = at
    }
}

@Model final class PostComment {
    @Attribute(.unique) var id: String
    var postID: String
    var author: String
    var text: String
    var createdAt: Date
    var convID: String
    var deleted: Bool = false
    init(id: String, postID: String, author: String, text: String, createdAt: Date, convID: String) {
        self.id = id; self.postID = postID; self.author = author; self.text = text; self.createdAt = createdAt; self.convID = convID
    }
}

@Model final class PostSeen {
    /// postID|userID
    @Attribute(.unique) var id: String
    var postID: String
    var user: String
    var at: Date
    init(postID: String, user: String, at: Date) {
        self.id = postID + "|" + user; self.postID = postID; self.user = user; self.at = at
    }
}

/// Named audiences ("Close family", "Gym clients") — lists of chats, kept on this device.
struct Audience: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var convIDs: [String]

    static var saved: [Audience] {
        get { Packed.decode([Audience].self, UserDefaults.standard.data(forKey: "views.audiences")) ?? [] }
        set { UserDefaults.standard.set(Packed.encode(newValue), forKey: "views.audiences") }
    }
}
