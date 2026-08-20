import Foundation

struct ResumePositionPolicy {
    static func shouldSave(position: TimeInterval, duration: TimeInterval) -> Bool {
        position > 5 && duration - position > 10
    }
}
