import Foundation

final class VoiceRefineXPCService: NSObject, VoiceRefineXPCProtocol {
    private let engine = VoiceRefineInferenceEngine()
    private let taskLock = NSLock()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false

    func prepare(
        _ requestData: NSData,
        withReply reply: @escaping (NSError?) -> Void
    ) {
        let request: VoiceRefinePrepareRequest
        do {
            request = try JSONDecoder().decode(
                VoiceRefinePrepareRequest.self,
                from: requestData as Data
            )
        } catch {
            reply(
                makeVoiceRefineXPCError(
                    .invalidRequest,
                    description: "Voice Refine received an invalid prepare request."
                )
            )
            return
        }

        let didStart = startTask(id: request.requestID, priority: .utility) {
            [engine] in
            do {
                try await engine.prepare(
                    modelDirectory: URL(fileURLWithPath: request.modelDirectoryPath),
                    systemPrompt: request.systemPrompt
                )
                reply(nil)
            } catch {
                reply(
                    makeVoiceRefineXPCError(
                        .inferenceFailed,
                        description: error.localizedDescription
                    )
                )
            }
        }
        guard didStart else {
            reply(
                makeVoiceRefineXPCError(
                    .connectionFailed,
                    description: "Voice Refine is shutting down."
                )
            )
            return
        }
    }

    func enhance(
        _ requestData: NSData,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    ) {
        let request: VoiceRefineEnhanceRequest
        do {
            request = try JSONDecoder().decode(
                VoiceRefineEnhanceRequest.self,
                from: requestData as Data
            )
        } catch {
            reply(
                nil,
                makeVoiceRefineXPCError(
                    .invalidRequest,
                    description: "Voice Refine received an invalid enhancement request."
                )
            )
            return
        }

        let didStart = startTask(id: request.requestID, priority: .userInitiated) {
            [engine] in
            do {
                let output = try await engine.enhance(
                    transcript: request.transcript,
                    modelDirectory: URL(fileURLWithPath: request.modelDirectoryPath),
                    systemPrompt: request.systemPrompt
                )
                let response = VoiceRefineEnhanceResponse(
                    requestID: request.requestID,
                    output: output
                )
                let responseData = try JSONEncoder().encode(response)
                reply(responseData as NSData, nil)
            } catch {
                reply(
                    nil,
                    makeVoiceRefineXPCError(
                        .inferenceFailed,
                        description: error.localizedDescription
                    )
                )
            }
        }
        guard didStart else {
            reply(
                nil,
                makeVoiceRefineXPCError(
                    .connectionFailed,
                    description: "Voice Refine is shutting down."
                )
            )
            return
        }
    }

    func shutdown(withReply reply: @escaping () -> Void) {
        let shutdownTask = beginShutdownIfNeeded(cancelActiveTasks: false)
        Task(priority: .utility) {
            await shutdownTask.value
            reply()
        }
    }

    func connectionInvalidated() async {
        let shutdownTask = beginShutdownIfNeeded(cancelActiveTasks: true)
        await shutdownTask.value
    }

    private func startTask(
        id: UUID,
        priority: TaskPriority,
        operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        taskLock.lock()
        guard !isShuttingDown else {
            taskLock.unlock()
            return false
        }

        let task = Task(priority: priority) { [weak self] in
            await operation()
            self?.removeTask(id: id)
        }
        activeTasks[id] = task
        taskLock.unlock()
        return true
    }

    private func removeTask(id: UUID) {
        taskLock.lock()
        activeTasks[id] = nil
        taskLock.unlock()
    }

    private func beginShutdownIfNeeded(
        cancelActiveTasks: Bool
    ) -> Task<Void, Never> {
        taskLock.lock()
        if let shutdownTask {
            taskLock.unlock()
            return shutdownTask
        }

        isShuttingDown = true
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        let engine = engine
        let shutdownTask = Task(priority: .utility) {
            if cancelActiveTasks {
                tasks.forEach { $0.cancel() }
            }
            for task in tasks {
                await task.value
            }
            await engine.unload()
        }
        self.shutdownTask = shutdownTask
        taskLock.unlock()
        return shutdownTask
    }
}
