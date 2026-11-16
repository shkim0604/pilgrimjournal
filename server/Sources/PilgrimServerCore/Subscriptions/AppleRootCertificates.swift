import Foundation

/// The trust anchor for App Store signed data (StoreKit 2 transactions, renewal info and App Store
/// Server Notifications V2): every `x5c` chain must end at Apple Root CA - G3.
///
/// The certificate is embedded so the server never fetches it at run time. It is
/// `https://www.apple.com/certificateauthority/AppleRootCA-G3.cer` (DER); `SubscriptionVerifierTests`
/// checks its self-signature and SHA-256 fingerprint.
public enum AppleRootCertificates {
    /// SHA-256 of the DER certificate, as Apple PKI publishes it.
    public static let appleRootCAG3SHA256 =
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"

    /// Apple Root CA - G3 (P-384, valid 2014-04-30 to 2039-04-30), DER.
    public static var appleRootCAG3: Data {
        guard let data = Data(base64Encoded: appleRootCAG3Base64) else {
            preconditionFailure("embedded Apple Root CA - G3 is not base64")
        }
        return data
    }

    static let appleRootCAG3Base64 =
        "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEcz"
        + "MSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjEL"
        + "MAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS"
        + "b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApB"
        + "cHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV"
        + "8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVzt"
        + "K517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQF"
        + "MAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+y"
        + "RhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkL"
        + "F1vLUagM6BgD56KyKA=="
}
