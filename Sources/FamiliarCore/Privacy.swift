import Foundation

/// Files Familiar never reads, whatever folder they're in: keys, certificates, credentials and password files,
/// found by name before reading, or by content when a harmless-looking text file turns out to hold a key. Their text
/// would otherwise end up in the index and in result snippets. Errs towards skipping: "secret-santa.txt" is skipped too.
public enum Privacy {
    /// File types that hold keys, certificates or passwords, by what they are.
    static let secretExtensions: Set<String> = [
        // Private keys and certificates. Not "key": that's Keynote's type too, and a private key saved as .key isn't a
        // Keynote package, so reading it fails and nothing of it is stored.
        "pem", "p8", "p12", "pfx", "crt", "cer", "der", "csr", "ppk", "keystore", "jks", "bks",
        // Encrypted files and keyrings
        "gpg", "pgp", "asc", "kbx", "age",
        // Password managers and their exports
        "kdbx", "kdb", "1pif", "1pux", "opvault", "agilekeychain", "psafe3", "keychain", "keychain-db",
        // Profiles that carry credentials
        "mobileprovision", "provisionprofile", "ovpn", "rdp",
        // Crypto wallets
        "wallet",
    ]
    /// Whole names of files that are credentials whatever they hold.
    static let secretNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "authorized_keys", "known_hosts", ".netrc", "_netrc",
        ".npmrc", ".pypirc", ".pgpass", ".my.cnf", ".htpasswd", "htpasswd", ".git-credentials", "credentials",
        "wallet.dat", "login data", "cookies", "keychain",
    ]
    /// The start of a name that marks one: `.env`, `.env.local`, `id_rsa.pub`, `secrets.yaml`…
    static let secretPrefixes = [".env", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "secret", "credential"]
    /// Words that mark a password or credentials file anywhere in its name ("bank passwords.txt").
    static let secretWords = [
        "password", "passwd", "passcode", "passphrase", "credential", "secret", "private key", "private_key",
        "privatekey", "recovery code", "recovery-code", "recovery_code", "backup code", "backup-code", "backup_code",
        "seed phrase", "seed-phrase", "seed_phrase", "mnemonic", "api key", "api-key", "api_key", "apikey",
        "access token", "access-token", "access_token", "auth token", "auth-token", "auth_token", "2fa codes",
    ]

    /// True for a file name that looks like a key, certificate or credentials file.
    public static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if secretExtensions.contains((lower as NSString).pathExtension) { return true }
        if secretNames.contains(lower) { return true }
        if secretPrefixes.contains(where: lower.hasPrefix) { return true }
        return secretWords.contains(where: lower.contains)
    }

    /// True for text that holds a private key or a cloud access key: checked after reading, before anything is
    /// stored, so such a file is skipped even under an ordinary name.
    public static func holdsSecret(_ text: String) -> Bool {
        let sample = text.prefix(200_000)
        if sample.contains("-----BEGIN") && sample.contains("PRIVATE KEY-----") { return true }
        if sample.range(of: #"\bAKIA[0-9A-Z]{16}\b"#, options: .regularExpression) != nil { return true }        // AWS key id
        if sample.range(of: #"aws_secret_access_key\s*[=:]"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if sample.range(of: #"\bsk-[A-Za-z0-9_-]{32,}"#, options: .regularExpression) != nil { return true }       // API secret keys
        if sample.range(of: #"\bgh[pousr]_[A-Za-z0-9]{36,}"#, options: .regularExpression) != nil { return true }   // GitHub tokens
        if sample.range(of: #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, options: .regularExpression) != nil { return true } // Slack tokens
        return false
    }

    /// csv, tsv and log files: off unless Settings → "Read data files" is on (`FAMILIAR_DATA_FILES=1` for the CLI).
    /// They're mostly exports and machine output, which flood an index and can hold other people's data.
    public static let dataExtensions: Set<String> = ["csv", "tsv", "log"]

    public static var readsDataFiles: Bool {
        if let env = ProcessInfo.processInfo.environment["FAMILIAR_DATA_FILES"] { return env == "1" }
        return SettingsStore.defaults.bool(forKey: "readDataFiles")
    }
}
