import Foundation

/// Serializes continuous PTZ movement and treats each move as a short lease.
/// The UI/plugin renews the lease while a control is held; if heartbeats stop,
/// the actor sends an automatic stop. Only one camera may move at a time.
actor PTZController {
    private let apiClient: ProtectAPIClient
    private var activeCameraID: String?
    private var generation: UInt64 = 0
    private var leaseTask: Task<Void, Never>?
    private var commandTail: Task<Bool, Never>?
    private var stopRetryCount = 0
    private let leaseSeconds: TimeInterval = 2

    init(apiClient: ProtectAPIClient) {
        self.apiClient = apiClient
    }

    func move(cameraID: String, x: Int, y: Int, z: Int) async {
        let moving = x != 0 || y != 0 || z != 0

        if !moving {
            _ = await stop(cameraID: cameraID)
            return
        }

        if let previousCamera = activeCameraID, previousCamera != cameraID {
            guard await stop(cameraID: previousCamera) else { return }
        }

        generation &+= 1
        let commandGeneration = generation
        activeCameraID = cameraID
        stopRetryCount = 0
        leaseTask?.cancel()

        let operation = enqueue { [apiClient] in
            try await apiClient.ptzMove(cameraID: cameraID, x: x, y: y, z: z)
        }
        let succeeded = await operation.value
        guard generation == commandGeneration else { return }
        guard succeeded else {
            await scheduleStopRetry(cameraID: cameraID)
            return
        }

        let leaseNanoseconds = UInt64(leaseSeconds * 1_000_000_000)
        leaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: leaseNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expire(cameraID: cameraID, generation: commandGeneration)
        }
    }

    @discardableResult
    func stop(cameraID: String? = nil) async -> Bool {
        generation &+= 1
        let commandGeneration = generation
        leaseTask?.cancel()
        leaseTask = nil

        let target = cameraID ?? activeCameraID
        guard let target = target else { return true }
        let operation = enqueue { [apiClient] in
            try await apiClient.ptzStop(cameraID: target)
        }
        let succeeded = await operation.value
        guard generation == commandGeneration else { return }
        if succeeded {
            if target == activeCameraID { activeCameraID = nil }
            stopRetryCount = 0
            return true
        } else {
            await scheduleStopRetry(cameraID: target)
            return false
        }
    }

    private func expire(cameraID: String, generation expected: UInt64) async {
        guard generation == expected, activeCameraID == cameraID else { return }
        activeCameraID = nil
        leaseTask = nil
        appLog("PTZ safety lease expired — stopping camera", .warn)
        let operation = enqueue { [apiClient] in
            try await apiClient.ptzStop(cameraID: cameraID)
        }
        if !(await operation.value) {
            activeCameraID = cameraID
            await scheduleStopRetry(cameraID: cameraID)
        }
    }

    private func enqueue(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Bool, Never> {
        let previous = commandTail
        let task = Task {
            if let previous = previous { _ = await previous.value }
            do {
                try await operation()
                return true
            } catch {
                appLog("PTZ command failed: \(error.localizedDescription)", .error)
                return false
            }
        }
        commandTail = task
        return task
    }

    private func scheduleStopRetry(cameraID: String) async {
        guard activeCameraID == cameraID, stopRetryCount < 6 else { return }
        stopRetryCount += 1
        let delay = min(pow(2.0, Double(stopRetryCount - 1)), 30)
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stop(cameraID: cameraID)
        }
    }
}
