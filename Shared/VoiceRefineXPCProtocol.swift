import Foundation

let voiceRefineXPCServiceName = "com.amoxichillin.Voice.RefineXPC"
let voiceRefineXPCErrorDomain = "com.amoxichillin.Voice.RefineXPC"

struct VoiceRefinePrepareRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
}

struct VoiceRefineEnhanceRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
    let transcript: String
}

struct VoiceRefineEnhanceResponse: Codable, Sendable {
    let requestID: UUID
    let output: String
}

enum VoiceRefineXPCErrorCode: Int {
    case invalidRequest = 1
    case inferenceFailed = 2
    case invalidResponse = 3
    case connectionFailed = 4
}

@objc protocol VoiceRefineXPCProtocol {
    func prepare(
        _ requestData: NSData,
        withReply reply: @escaping (NSError?) -> Void
    )

    func enhance(
        _ requestData: NSData,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    )

    func shutdown(withReply reply: @escaping () -> Void)
}

func makeVoiceRefineXPCError(
    _ code: VoiceRefineXPCErrorCode,
    description: String
) -> NSError {
    NSError(
        domain: voiceRefineXPCErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}
