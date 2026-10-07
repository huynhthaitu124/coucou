import Foundation
import AppKit

// MARK: - Autonomous Mission Structures

struct AutonomousStep: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var status: StepStatus
    var detail: String?

    enum StepStatus: String, Codable {
        case pending    = "pending"
        case inProgress = "in_progress"
        case completed  = "completed"
        case failed     = "failed"
    }

    init(id: String = UUID().uuidString, title: String, status: StepStatus = .pending, detail: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

struct AutonomousMission: Identifiable, Codable, Equatable {
    let id: String
    let goal: String
    var steps: [AutonomousStep]
    var currentStepIndex: Int
    var scratchpad: String
    var iteration: Int
    var maxIterations: Int
    var isCompleted: Bool
    var finalSummary: String?
    var startedAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        goal: String,
        steps: [AutonomousStep] = [],
        currentStepIndex: Int = 0,
        scratchpad: String = "",
        iteration: Int = 0,
        maxIterations: Int = 50,
        isCompleted: Bool = false,
        finalSummary: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.scratchpad = scratchpad
        self.iteration = iteration
        self.maxIterations = maxIterations
        self.isCompleted = isCompleted
        self.finalSummary = finalSummary
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Autonomous Agent Engine
// Manages goal-driven multi-step execution, dynamic checklists, scratchpad memory,
// and verification gates for Grokbot.

@MainActor
final class AutonomousAgentEngine: ObservableObject {
    static let shared = AutonomousAgentEngine()

    @Published var currentMission: AutonomousMission? = nil
    @Published var isRunning: Bool = false

    private init() {}

    /// Starts a new autonomous mission with a goal.
    @discardableResult
    func startMission(goal: String, state: AppState) -> AutonomousMission {
        let initialStep = AutonomousStep(title: "Phân tích mục tiêu & khởi tạo kế hoạch", status: .inProgress)
        let mission = AutonomousMission(
            goal: goal,
            steps: [initialStep],
            currentStepIndex: 0,
            scratchpad: "Mục tiêu ban đầu: \(goal)",
            maxIterations: 50
        )
        self.currentMission = mission
        self.isRunning = true

        // Register as an active task in AppState so it appears on Notch / Dynamic Island
        let agentTask = AgentTask(
            id: mission.id,
            name: String(goal.prefix(35)),
            color: "#8B5CF6", // Purple autonomous accent
            state: .working,
            stepIndex: 0,
            steps: [initialStep.title],
            source: .agent
        )
        state.addTask(agentTask)
        state.setFocus(mission.id)
        state.stateOverride = .working

        coucouLog("[Autonomous] Mission started: '\(goal)'")
        return mission
    }

    /// Updates the plan checklist and active step.
    func updatePlan(steps: [String], currentStepIndex: Int, completedIndices: [Int] = [], state: AppState? = nil) -> String {
        guard var mission = currentMission else {
            return "Không có nhiệm vụ tự chủ nào đang hoạt động."
        }

        var newSteps: [AutonomousStep] = []
        for (idx, stepTitle) in steps.enumerated() {
            var status: AutonomousStep.StepStatus = .pending
            if completedIndices.contains(idx) || idx < currentStepIndex {
                status = .completed
            } else if idx == currentStepIndex {
                status = .inProgress
            }
            newSteps.append(AutonomousStep(title: stepTitle, status: status))
        }

        mission.steps = newSteps
        mission.currentStepIndex = min(max(0, currentStepIndex), max(0, newSteps.count - 1))
        mission.updatedAt = Date()
        self.currentMission = mission

        // Sync with AppState AgentTask for live Notch display
        let targetState = state ?? AppState.shared
        if let taskIdx = targetState.tasks.firstIndex(where: { $0.id == mission.id }) {
            targetState.tasks[taskIdx].steps = steps
            targetState.tasks[taskIdx].stepIndex = mission.currentStepIndex
            targetState.tasks[taskIdx].state = .working
        }

        let currentTitle = mission.steps.indices.contains(mission.currentStepIndex) ? mission.steps[mission.currentStepIndex].title : "Đang thực hiện"
        let msg = "Kế hoạch đã được cập nhật (\(mission.steps.count) bước). Đang ở bước \(mission.currentStepIndex + 1)/\(mission.steps.count): \"\(currentTitle)\"."
        coucouLog("[Autonomous] Plan updated: \(msg)")
        return msg
    }

    /// Updates working scratchpad memory notes.
    func updateScratchpad(notes: String) -> String {
        guard var mission = currentMission else {
            return "Không có nhiệm vụ tự chủ nào đang hoạt động."
        }
        mission.scratchpad = notes
        mission.updatedAt = Date()
        self.currentMission = mission
        coucouLog("[Autonomous] Scratchpad updated: \(notes.prefix(80))...")
        return "Đã cập nhật bộ nhớ làm việc (scratchpad)."
    }

    /// Concludes the mission with verified success.
    func completeMission(summary: String, state: AppState? = nil) -> String {
        guard var mission = currentMission else {
            return "Mục tiêu đã được ghi nhận."
        }
        mission.isCompleted = true
        mission.finalSummary = summary
        mission.updatedAt = Date()
        for i in 0..<mission.steps.count {
            mission.steps[i].status = .completed
        }
        self.currentMission = mission
        self.isRunning = false

        // Update AppState
        let targetState = state ?? AppState.shared
        if let taskIdx = targetState.tasks.firstIndex(where: { $0.id == mission.id }) {
            targetState.tasks[taskIdx].state = .finished
        }
        targetState.stateOverride = nil

        // Trigger celebratory reactions
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
        NotificationCenter.default.post(name: .botParticle, object: Particle.ParticleType.star)
        SoundEngine.shared.play("finish")

        coucouLog("[Autonomous] Mission COMPLETED: '\(mission.goal)'")
        return "Nhiệm vụ tự chủ đã được xác nhận HOÀN TẤT THÀNH CÔNG!"
    }

    /// Stops or cancels active mission.
    func stopMission(state: AppState? = nil) {
        if var mission = currentMission {
            mission.isCompleted = true
            self.currentMission = mission
        }
        self.isRunning = false
        let targetState = state ?? AppState.shared
        if let m = currentMission, let taskIdx = targetState.tasks.firstIndex(where: { $0.id == m.id }) {
            targetState.tasks[taskIdx].state = .idle
        }
        targetState.stateOverride = nil
        coucouLog("[Autonomous] Mission stopped by user.")
    }
}
