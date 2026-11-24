import Foundation
import UIKit
import CryptoKit
import UniformTypeIdentifiers

/// Photos and files: encrypted on this device with a fresh key, uploaded once as a CloudKit asset,
/// and the key travels inside the (already encrypted) message.
@MainActor
enum Attachments {
    /// iCloud's limit per file is 250 MB; we keep a margin for encryption.
    static let maxFileBytes = 200 * 1024 * 1024
    /// "Original" quality: photos and videos are sent untouched, with their metadata (date, place, camera).
    static var sendOriginal: Bool {
        get { UserDefaults.standard.bool(forKey: "media.original") }
        set { UserDefaults.standard.set(newValue, forKey: "media.original") }
    }

    enum Failure: LocalizedError {
        case tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Files up to 200 MB can be sent (iCloud's per-file limit)."
            case .unreadable: "Couldn't read that file."
            }
        }
    }

    struct Prepared {
        var ref: AttachmentRef
        /// blob ID → outgoing file name
        var upload: (String, String)
    }

    nonisolated private static func dir(_ name: String) -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated static func outgoingURL(_ name: String) -> URL { dir("Outgoing").appendingPathComponent(name) }
    nonisolated static func cacheURL(_ ref: AttachmentRef) -> URL {
        let ext = (ref.name as NSString).pathExtension
        return dir("Attachments").appendingPathComponent(ext.isEmpty ? ref.id : "\(ref.id).\(ext)")
    }

    nonisolated static func prepareImage(_ data: Data, original: Bool = false) throws -> Prepared {
        guard let img = UIImage(data: data) else { throw Failure.unreadable }
        if original {
            // Untouched file: full resolution, EXIF date/location/camera kept.
            let (ext, mime) = imageType(data)
            let thumb = img.scaled(maxSide: 240).jpegData(compressionQuality: 0.6)
            var p = try prepare(data, name: "Original.\(ext)", mime: mime, kind: "image")
            p.ref.width = Double(img.size.width)
            p.ref.height = Double(img.size.height)
            p.ref.thumb = thumb
            return p
        }
        let full = img.scaled(maxSide: 2048)
        guard let jpg = full.jpegData(compressionQuality: 0.8) else { throw Failure.unreadable }
        let thumb = img.scaled(maxSide: 240).jpegData(compressionQuality: 0.6)
        var p = try prepare(jpg, name: "Photo.jpg", mime: "image/jpeg", kind: "image")
        p.ref.width = Double(full.size.width)
        p.ref.height = Double(full.size.height)
        p.ref.thumb = thumb
        return p
    }

    /// Same as prepareImage, but scaled, compressed and encrypted off the main thread so the chat never freezes.
    static func prepareImageAsync(_ data: Data, original: Bool = false) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) { try Attachments.prepareImage(data, original: original) }.value
    }

    /// Recognises the real format of an image file from its first bytes.
    nonisolated static func imageType(_ d: Data) -> (String, String) {
        let b = [UInt8](d.prefix(16))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return ("png", "image/png") }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return ("jpg", "image/jpeg") }
        if b.count >= 12, let brand = String(bytes: b[4..<12], encoding: .ascii), brand.hasPrefix("ftyp") {
            if brand.contains("avif") { return ("avif", "image/avif") }
            return ("heic", "image/heic")
        }
        if b.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return ("gif", "image/gif") }
        return ("jpg", "image/jpeg")
    }

    static func prepareFile(_ url: URL) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if mime.hasPrefix("image/"), data.count < 20 * 1024 * 1024 { return try prepareImage(data) }
        return try prepare(data, name: url.lastPathComponent, mime: mime, kind: "file")
    }

    nonisolated static func prepare(_ plain: Data, name: String, mime: String, kind: String) throws -> Prepared {
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
