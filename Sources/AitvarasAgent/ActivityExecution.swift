import Foundation
import AitvarasCore
import AitvarasStore

/// Fail closed for unattended optional work, but never block explicit actions
/// or the persistence of their source material.
public enum ActivityExecution {
    public static func permits(_ feature: BackgroundFeature, stores: Stores,
                        reporter: ActivityReporter? = nil,
                        trigger: ActivityTrigger = ActivityTaskContext.trigger) -> Bool {
        if trigger == .manual { return true }
        guard reporter?.failureMessage == nil else { return false }
        return (try? stores.backgroundWorkPolicy().permits(feature, trigger: trigger)) == true
    }
}
