import Crypto
import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// `POST /api/v1/uploads`, `GET /api/v1/media/:id` and the signed file route
/// `GET /api/media-files/:id?exp&sig` (design.md 7절, "사진" API).
enum MediaRoutes {
    /// `routes`: `/api/v1` with a signed-in user whose account exists and is not suspended
    /// (sign-up is checked per purpose). `root`: no checks; the signature is the authorization.
    static func register(routes: any RoutesBuilder, root: any RoutesBuilder) {
        routes.post("uploads", use: upload)
        routes.get("media", ":id", use: mediaURL)
        root.get("api", "media-files", ":id", use: file)
    }

    // MARK: - POST /uploads

    /// multipart `purpose`, `clientId`, `groupId` (all but `profile`), `file` → 201
    /// `UploadResponse`, or 200 with the first upload for a repeated `clientId`.
    ///
    /// Group photos need a finished sign-up, the subscription when required, membership (404
    /// otherwise) and a group that is not waiting to be deleted (409, nothing could be attached
    /// there). The file is checked and stripped of metadata (`UploadValidation`), written to the
    /// media store, then the row is inserted; if the insert does not happen the file is removed.
    @Sendable static func upload(_ req: Request) async throws -> Response {
        let user = try await req.currentUser()
        let viewer = try user.requireID()
        let form = try req.content.decode(UploadForm.self)
        let fields = try UploadFields.parse(
            purpose: form.purpose, clientId: form.clientId, groupId: form.groupId)
        if let groupID = fields.groupID {
            try await MediaAccountCheck.requireGroupMember(user, req)
            let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: req.db)
            try ContentAccess.requireWritable(group)
        }
        let signer = MediaURLSigner(config: req.pilgrimConfig)

        let existing: @Sendable (any Database) async throws -> Media? = { db in
            try await Media.query(on: db)
                .filter(\.$uploader.$id == viewer)
                .filter(\.$clientID == fields.clientID)
                .first()
        }
        if let first = try await existing(req.db) {
            return try .pilgrimJSON(UploadResponse(media: try signer.ref(for: first)))
        }

        try await ContentAccess.consumeRateLimit(req, bucket: "uploads", rule: \.uploads)
        let image = try UploadValidation.validate(
            purpose: fields.purpose, contentType: form.file.contentType,
            data: Data(buffer: form.file.data))
        let mediaID = UUID()
        let path = MediaPaths.relativePath(for: mediaID)
        let digest = Data(SHA256.hash(data: image.data))
        let store = req.mediaStore
        try await store.write(image.data, to: path)

        let outcome: Idempotency.Outcome<Media>
        do {
            outcome = try await Idempotency.findOrCreate(
                on: req.db, existing: existing,
                create: { db in
                    let media = Media(
                        id: mediaID, uploaderID: viewer, purpose: fields.purpose,
                        groupID: fields.groupID, filePath: path, byteCount: image.data.count,
                        width: image.width, height: image.height, sha256: digest,
                        clientID: fields.clientID)
                    try await media.create(on: db)
                    return media
                })
        } catch {
            try? await store.delete(path)
            throw error
        }
        if !outcome.created {
            // A concurrent request with the same clientId won; this file is not referenced.
            try? await store.delete(path)
        }
        return try .pilgrimJSON(
            UploadResponse(media: try signer.ref(for: outcome.value)), status: outcome.status)
    }

    // MARK: - GET /media/:id

    /// → `MediaURLResponse` with a fresh 10-minute URL, for a photo the viewer may see
    /// (`MediaAccess`); 404 otherwise.
    @Sendable static func mediaURL(_ req: Request) async throws -> Response {
        let user = try await req.currentUser()
        let viewer = try user.requireID()
        let mediaID = try GroupAccess.uuidParameter("id", of: req)
        guard let media = try await Media.find(mediaID, on: req.db) else {
            throw APIError.notFound()
        }
        if media.purpose != .profile, media.$uploader.id != viewer {
            try await MediaAccountCheck.requireGroupMember(user, req)
        }
        guard try await MediaAccess.canView(media, viewer: viewer, on: req.db) else {
            throw APIError.notFound()
        }
        let signed = MediaURLSigner(config: req.pilgrimConfig).signedURL(for: mediaID)
        return try .pilgrimJSON(MediaURLResponse(url: signed.url, expiresAt: signed.expiresAt))
    }

    // MARK: - GET /api/media-files/:id?exp&sig

    /// → the JPEG, `Cache-Control: private, max-age=600`. A missing, wrong or expired signature
    /// is 403 (the app asks `GET /media/:id` for a new URL); a deleted photo is 404.
    @Sendable static func file(_ req: Request) async throws -> Response {
        let mediaID = try GroupAccess.uuidParameter("id", of: req)
        try SignedMediaFile.verify(
            mediaID: mediaID, expiry: req.query[String.self, at: "exp"],
            signature: req.query[String.self, at: "sig"],
            signer: MediaURLSigner(config: req.pilgrimConfig))
        guard let media = try await Media.find(mediaID, on: req.db),
            let data = try await req.mediaStore.read(media.filePath)
        else { throw APIError.notFound() }
        return SignedMediaFile.response(data)
    }
}

/// The checks and headers of the signed file route, apart from the database.
enum SignedMediaFile {
    /// `Cache-Control` of a served file: private (it belongs to a group) and no longer than the
    /// URL lives. The file never changes, so the app also caches it by media ID.
    static let cacheControl = "private, max-age=\(Int(MediaRef.signedURLLifetime))"

    /// Throws 403 `FORBIDDEN` unless `signature` is the server's signature of
    /// `"<mediaID>.<expiry>"` and `expiry` (unix seconds) has not passed.
    static func verify(
        mediaID: UUID, expiry: String?, signature: String?, signer: MediaURLSigner,
        now: Date = Date()
    ) throws {
        guard let expiry, let seconds = Int(expiry), let signature,
            signer.isValid(mediaID: mediaID, expiry: seconds, signature: signature, now: now)
        else { throw APIError.forbidden("the media URL is invalid or has expired") }
    }

    static func response(_ data: Data) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .jpeg
        headers.replaceOrAdd(name: .cacheControl, value: cacheControl)
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}
