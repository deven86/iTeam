import Foundation
import UIKit
import CryptoKit
import UniformTypeIdentifiers

/// Photos and files: encrypted on this device with a fresh key, uploaded once as a CloudKit asset,
/// and the key travels inside the (already encrypted) message.
@MainActor
enum Attachments {
    static let maxFileBytes = 25 * 1024 * 1024

    enum Failure: LocalizedError {
        case tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Files up to 25 MB can be sent."
            case .unreadable: "Couldn't read that file."
            }
        }
    }

    struct Prepared {
        var ref: AttachmentRef
        /// blob ID → outgoing file name
        var upload: (String, String)
    }

    private static func dir(_ name: String) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func outgoingURL(_ name: String) -> URL { dir("Outgoing").appendingPathComponent(name) }
    static func cacheURL(_ ref: AttachmentRef) -> URL {
        let ext = (ref.name as NSString).pathExtension
        return dir("Attachments").appendingPathComponent(ext.isEmpty ? ref.id : "\(ref.id).\(ext)")
    }

    static func prepareImage(_ data: Data) throws -> Prepared {
        guard let img = UIImage(data: data) else { throw Failure.unreadable }
        let full = img.scaled(maxSide: 2048)
        guard let jpg = full.jpegData(compressionQuality: 0.8) else { throw Failure.unreadable }
        let thumb = img.scaled(maxSide: 240).jpegData(compressionQuality: 0.6)
        var p = try prepare(jpg, name: "Photo.jpg", mime: "image/jpeg", kind: "image")
        p.ref.width = Double(full.size.width)
        p.ref.height = Double(full.size.height)
        p.ref.thumb = thumb
        return p
    }

    static func prepareFile(_ url: URL) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if mime.hasPrefix("image/"), data.count < 20 * 1024 * 1024 { return try prepareImage(data) }
        return try prepare(data, name: url.lastPathComponent, mime: mime, kind: "file")
    }

    static func prepare(_ plain: Data, name: String, mime: String, kind: String) throws -> Prepared {
        guard plain.count <= maxFileBytes else { throw Failure.tooLarge }
        let key = SymmetricKey(size: .bits256)
        let sealed = try E2E.seal(plain, key: key)
        let blobID = "B" + UUID().uuidString
        let file = blobID + ".bin"
        try sealed.write(to: outgoingURL(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let ref = AttachmentRef(id: UUID().uuidString, blob: blobID, key: E2E.keyData(key).base64EncodedString(),
                                name: name, mime: mime, size: plain.count, kind: kind)
        try? plain.write(to: cacheURL(ref), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return Prepared(ref: ref, upload: (blobID, file))
    }

    /// The decrypted file on this device, downloading it first if needed.
    static func load(_ ref: AttachmentRef) async throws -> URL {
        let url = cacheURL(ref)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sealed = try await CloudService.shared.fetchBlob(ref.blob)
        guard let keyData = Data(base64Encoded: ref.key) else { throw Failure.unreadable }
        let plain = try E2E.open(sealed, key: SymmetricKey(data: keyData))
        try plain.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func cachedImage(_ ref: AttachmentRef) -> UIImage? {
        UIImage(contentsOfFile: cacheURL(ref).path)
    }

    /// Size of downloaded attachments on this device.
    static func cacheSize() -> Int {
        let d = dir("Attachments")
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: dir("Attachments"))
    }
}

extension UIImage {
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let s = maxSide / longest
        let target = CGSize(width: size.width * s, height: size.height * s)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
