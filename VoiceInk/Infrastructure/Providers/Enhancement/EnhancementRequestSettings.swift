import Foundation

enum EnhancementRequestSettings {
    static let timeoutKey = "EnhancementTimeoutSeconds"
    static let retryOnTimeoutKey = "EnhancementRetryOnTimeout"
    static let defaultTimeoutSeconds = 7
    static let defaultRetryOnTimeout = true
    static let maximumAttempts = 3

    static var timeout: TimeInterval {
        let configuredTimeout = UserDefaults.standard.integer(forKey: timeoutKey)
        return TimeInterval(configuredTimeout > 0 ? configuredTimeout : defaultTimeoutSeconds)
    }

    /// The timeout covers the whole response, and the response grows with the transcript,
    /// so long dictations get extra time on top of the configured value.
    static func timeout(forInput text: String) -> TimeInterval {
        let extraWords = max(0, WordCounter.count(in: text) - 100)
        let scaledTimeout = timeout + Double(extraWords) * 0.12
        return min(scaledTimeout, max(timeout, 180))
    }

    static var retryOnTimeout: Bool {
        guard UserDefaults.standard.object(forKey: retryOnTimeoutKey) != nil else {
            return defaultRetryOnTimeout
        }
        return UserDefaults.standard.bool(forKey: retryOnTimeoutKey)
    }
}
