import Foundation

/// The fields of App Store signed payloads the server uses. Apple sends dates as milliseconds
/// since 1970 (`AppStorePayloadDecoding.decoder`). Unknown fields are ignored.

/// A StoreKit 2 `Transaction.jwsRepresentation` / `JWSTransaction` payload.
public struct AppStoreTransaction: Sendable, Equatable, Decodable {
    public var originalTransactionID: String
    public var transactionID: String
    public var bundleID: String
    public var productID: String
    /// `Production`, `Sandbox`, `Xcode` or `LocalTesting`; the verifier only lets the first two in.
    public var environment: String
    public var purchaseDate: Date?
    public var expiresDate: Date?
    public var revocationDate: Date?
    /// The `appAccountToken` given at purchase — the server user ID (design.md 12절). nil when
    /// the purchase did not set one or it is not a UUID.
    public var appAccountToken: UUID?
    public var storefront: String?
    public var signedDate: Date?

    public init(
        originalTransactionID: String, transactionID: String, bundleID: String,
        productID: String, environment: String, purchaseDate: Date? = nil,
        expiresDate: Date? = nil, revocationDate: Date? = nil, appAccountToken: UUID? = nil,
        storefront: String? = nil, signedDate: Date? = nil
    ) {
        self.originalTransactionID = originalTransactionID
        self.transactionID = transactionID
        self.bundleID = bundleID
        self.productID = productID
        self.environment = environment
        self.purchaseDate = purchaseDate
        self.expiresDate = expiresDate
        self.revocationDate = revocationDate
        self.appAccountToken = appAccountToken
        self.storefront = storefront
        self.signedDate = signedDate
    }

    enum CodingKeys: String, CodingKey {
        case originalTransactionID = "originalTransactionId"
        case transactionID = "transactionId"
        case bundleID = "bundleId"
        case productID = "productId"
        case environment, purchaseDate, expiresDate, revocationDate, appAccountToken, storefront
        case signedDate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalTransactionID = try container.decode(String.self, forKey: .originalTransactionID)
        transactionID = try container.decode(String.self, forKey: .transactionID)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        productID = try container.decode(String.self, forKey: .productID)
        environment = try container.decode(String.self, forKey: .environment)
        purchaseDate = try container.decodeIfPresent(Date.self, forKey: .purchaseDate)
        expiresDate = try container.decodeIfPresent(Date.self, forKey: .expiresDate)
        revocationDate = try container.decodeIfPresent(Date.self, forKey: .revocationDate)
        appAccountToken = try container.decodeIfPresent(String.self, forKey: .appAccountToken)
            .flatMap(UUID.init(uuidString:))
        storefront = try container.decodeIfPresent(String.self, forKey: .storefront)
        signedDate = try container.decodeIfPresent(Date.self, forKey: .signedDate)
    }
}

/// A `JWSRenewalInfo` payload (`signedRenewalInfo`).
public struct AppStoreRenewalInfo: Sendable, Equatable, Decodable {
    public var originalTransactionID: String?
    public var environment: String?
    /// When the billing grace period ends (`DID_FAIL_TO_RENEW` / `GRACE_PERIOD`).
    public var gracePeriodExpiresDate: Date?
    public var isInBillingRetryPeriod: Bool?
    public var signedDate: Date?

    public init(
        originalTransactionID: String? = nil, environment: String? = nil,
        gracePeriodExpiresDate: Date? = nil, isInBillingRetryPeriod: Bool? = nil,
        signedDate: Date? = nil
    ) {
        self.originalTransactionID = originalTransactionID
        self.environment = environment
        self.gracePeriodExpiresDate = gracePeriodExpiresDate
        self.isInBillingRetryPeriod = isInBillingRetryPeriod
        self.signedDate = signedDate
    }

    enum CodingKeys: String, CodingKey {
        case originalTransactionID = "originalTransactionId"
        case environment, gracePeriodExpiresDate, isInBillingRetryPeriod, signedDate
    }
}

/// The decoded `signedPayload` of an App Store Server Notification V2.
public struct AppStoreNotificationPayload: Sendable, Equatable, Decodable {
    public struct NotificationData: Sendable, Equatable, Decodable {
        public var bundleID: String?
        public var environment: String?
        public var signedTransactionInfo: String?
        public var signedRenewalInfo: String?
        /// 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
        public var status: Int?

        public init(
            bundleID: String?, environment: String?, signedTransactionInfo: String? = nil,
            signedRenewalInfo: String? = nil, status: Int? = nil
        ) {
            self.bundleID = bundleID
            self.environment = environment
            self.signedTransactionInfo = signedTransactionInfo
            self.signedRenewalInfo = signedRenewalInfo
            self.status = status
        }

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case environment, signedTransactionInfo, signedRenewalInfo, status
        }
    }

    /// `summary` notifications (`RENEWAL_EXTENSION`) carry only the app identity.
    public struct NotificationSummary: Sendable, Equatable, Decodable {
        public var bundleID: String?
        public var environment: String?

        public init(bundleID: String?, environment: String?) {
            self.bundleID = bundleID
            self.environment = environment
        }

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundleId"
            case environment
        }
    }

    public var notificationType: String
    public var subtype: String?
    public var notificationUUID: UUID
    public var signedDate: Date?
    public var data: NotificationData?
    public var summary: NotificationSummary?

    public init(
        notificationType: String, subtype: String? = nil, notificationUUID: UUID,
        signedDate: Date? = nil, data: NotificationData? = nil,
        summary: NotificationSummary? = nil
    ) {
        self.notificationType = notificationType
        self.subtype = subtype
        self.notificationUUID = notificationUUID
        self.signedDate = signedDate
        self.data = data
        self.summary = summary
    }

    /// The app the notification is about, from `data` or `summary`.
    var appBundleID: String? { data?.bundleID ?? summary?.bundleID }
    var appEnvironment: String? { data?.environment ?? summary?.environment }
}

/// One `GET /inApps/v1/subscriptions/{transactionId}` answer (App Store Server API
/// `getAllSubscriptionStatuses`).
public struct AppStoreStatusResponse: Sendable, Equatable, Decodable {
    public struct LastTransaction: Sendable, Equatable, Decodable {
        public var originalTransactionID: String?
        /// 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
        public var status: Int?
        public var signedTransactionInfo: String?
        public var signedRenewalInfo: String?

        public init(
            originalTransactionID: String?, status: Int?, signedTransactionInfo: String?,
            signedRenewalInfo: String?
        ) {
            self.originalTransactionID = originalTransactionID
            self.status = status
            self.signedTransactionInfo = signedTransactionInfo
            self.signedRenewalInfo = signedRenewalInfo
        }

        enum CodingKeys: String, CodingKey {
            case originalTransactionID = "originalTransactionId"
            case status, signedTransactionInfo, signedRenewalInfo
        }
    }

    public struct SubscriptionGroup: Sendable, Equatable, Decodable {
        public var lastTransactions: [LastTransaction]?

        public init(lastTransactions: [LastTransaction]?) {
            self.lastTransactions = lastTransactions
        }
    }

    public var data: [SubscriptionGroup]?

    public init(data: [SubscriptionGroup]?) {
        self.data = data
    }

    /// The entry for `originalTransactionID`, if Apple returned one.
    func lastTransaction(for originalTransactionID: String) -> LastTransaction? {
        (data ?? []).lazy.compactMap(\.lastTransactions).joined()
            .first { $0.originalTransactionID == originalTransactionID }
    }
}

enum AppStorePayloadDecoding {
    /// Apple's signed payloads use milliseconds since 1970 for every date.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
