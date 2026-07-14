import Foundation

/// Serializes continuous PTZ movement and treats each move as a short lease.
/// The UI/plugin renews the lease while a control is held; if heartbeats stop,
/// the actor sends an automatic stop. Only one camera may move at a time.
actor PTZController {
    private let apiClient: ProtectAPIClient
    private var activeCameraID: String?
    private var generation: UInt64 = 0
    private var leaseTask: Task<Void, Never>?
    private let leaseSeconds: TimeInterval = 2

    init(apiClient: ProtectAPIClient) {
        self.apiClient = apiClient
    }

    func move(cameraID: String, x: Int, y: Int, z: Int) async {
        let moving = x != 0 || y != 0 || z != 0

        if !moving {
            await stop(cameraID: cameraID)
            return
        }

        // Never leave a previous camera moving when control changes target.
        if let previous = activeCameraID, previous != cameraID {
            try? await apiClient.ptzStop(cameraID: previous)
        }

        generation &+= 1
        let commandGeneration = generation
        activeCameraID = cameraID
        leaseTask?.cancel()

        do {
            try await apiClient.ptzMove(cameraID: cameraID, x: x, y: y, z: z)
        } catch {
            activeCameraID = nil
            appLog("PTZ move failed: \(error.localizedDescription)", .error)
            return
        }

        let leaseNanoseconds = UInt64(leaseSeconds * 1_000_000_000)
        leaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: leaseNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expire(cameraID: cameraID, generation: commandGeneration)
        }
    }

    func stop(cameraID: String? = nil) async {
        generation &+= 1
        leaseTask?.cancel()
        leaseTask = nil

        let target = cameraID ?? activeCameraID
        if target == activeCameraID { activeCameraID = nil }
        guard let target = target else { return }
        do {
            try await apiClient.ptzStop(cameraID: target)
        } catch {
            appLog("PTZ stop failed for \(target): \(error.localizedDescription)", .error)
        }
    }

    private func expire(cameraID: String, generation expected: UInt64) async {
        guard generation == expected, activeCameraID == cameraID else { return }
        activeCameraID = nil
        leaseTask = nil
        appLog("PTZ safety lease expired — stopping camera", .warn)
        try? await apiClient.ptzStop(cameraID: cameraID)
    }
}
