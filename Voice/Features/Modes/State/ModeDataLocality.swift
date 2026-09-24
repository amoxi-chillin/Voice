import Foundation

/// Tells whether a mode's audio and text stay on this Mac or the user's own network.
@MainActor
enum ModeDataLocality {
    static func isOnDevice(_ model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .whisper, .fluidAudio, .transcribeCpp, .nativeApple:
            return true
        case .custom:
            return (model as? CustomCloudModel).map { isLocalURL($0.apiEndpoint) } ?? false
        default:
            return false
        }
    }

    static func isOnDevice(_ provider: AIProvider, modelName: String?) -> Bool {
        switch provider {
        case .voiceRefine, .localCLI:
            return true
        case .ollama:
            return isLocalURL(provider.baseURL)
        case .custom:
            guard let modelName,
                let config = CustomAIProviderManager.shared.provider(forModel: modelName)
            else {
                return false
            }
            return isLocalURL(config.baseURL)
        default:
            return false
        }
    }

    static func isLocalURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasSuffix(".local")
    }
}
