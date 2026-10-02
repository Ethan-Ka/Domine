import AppKit
import Foundation
import Testing
@testable import Domine

@MainActor
struct CallbackThreadTests {
    @Test func mainQueueObserverPostedFromBackgroundDoesNotTrap() async {
        let center = NotificationCenter()
        let name = Notification.Name("domine.test")
        nonisolated(unsafe) var fired = 0
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { fired += 1 }
        }
        await withCheckedContinuation { c in
            DispatchQueue.global().async { center.post(name: name, object: nil); c.resume() }
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fired == 1)
        center.removeObserver(token)
    }
}
