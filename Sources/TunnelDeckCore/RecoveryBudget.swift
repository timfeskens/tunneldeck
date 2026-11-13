import Foundation

public struct RecoveryBudget: Sendable {
    public static let delays: [TimeInterval] = [5, 15, 30]
    public private(set) var attempts = 0
    private var nextAttempt: Date

    public init(now: Date = Date()) {
        nextAttempt = now.addingTimeInterval(Self.delays[0])
    }

    public var exhausted: Bool { attempts >= Self.delays.count }

    public mutating func takeAttempt(now: Date = Date()) -> Bool {
        guard !exhausted, now >= nextAttempt else { return false }
        attempts += 1
        if !exhausted { nextAttempt = now.addingTimeInterval(Self.delays[attempts]) }
        return true
    }
}

public struct RouteRecoveryStatus: Codable, Sendable {
    public let attempts: Int
    public let exhausted: Bool
    public let message: String

    public init(attempts: Int, exhausted: Bool, message: String) {
        self.attempts = attempts
        self.exhausted = exhausted
        self.message = message
    }
}
