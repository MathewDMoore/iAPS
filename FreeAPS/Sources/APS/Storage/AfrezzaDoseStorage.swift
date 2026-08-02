import Foundation
import Swinject

protocol AfrezzaDoseObserver {
    func afrezzaDosesDidUpdate(_ events: [AfrezzaDoseEvent])
}

protocol AfrezzaDoseStorage {
    func store(_ event: AfrezzaDoseEvent)
    func store(_ events: [AfrezzaDoseEvent])
    func recent(since date: Date) -> [AfrezzaDoseEvent]
    func all() -> [AfrezzaDoseEvent]
    func delete(id: String)
}

final class BaseAfrezzaDoseStorage: AfrezzaDoseStorage, Injectable {
    private static let file = "afrezza-dose-history.json"
    private static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let processQueue = DispatchQueue(
        label: "BaseAfrezzaDoseStorage.processQueue"
    )

    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func store(_ event: AfrezzaDoseEvent) {
        store([event])
    }

    func store(_ events: [AfrezzaDoseEvent]) {
        guard !events.isEmpty else { return }

        processQueue.sync {
            storage.transaction { storage in
                var saved = storage.retrieve(
                    Self.file,
                    as: [AfrezzaDoseEvent].self
                ) ?? []

                for event in events where event.cartridgeUnits > 0 {
                    if let index = saved.firstIndex(where: { $0.id == event.id }) {
                        saved[index] = event
                    } else {
                        saved.append(event)
                    }
                }

                let cutoff = Date().addingTimeInterval(-Self.retentionInterval)

                saved = saved
                    .filter { $0.date >= cutoff }
                    .sorted { $0.date > $1.date }

                storage.save(saved, as: Self.file)

                broadcaster.notify(
                    AfrezzaDoseObserver.self,
                    on: processQueue
                ) {
                    $0.afrezzaDosesDidUpdate(saved)
                }
            }
        }
    }

    func recent(since date: Date) -> [AfrezzaDoseEvent] {
        processQueue.sync {
            allUnlocked()
                .filter { $0.date >= date }
                .sorted { $0.date > $1.date }
        }
    }

    func all() -> [AfrezzaDoseEvent] {
        processQueue.sync {
            allUnlocked()
        }
    }

    func delete(id: String) {
        processQueue.sync {
            storage.transaction { storage in
                var saved = storage.retrieve(
                    Self.file,
                    as: [AfrezzaDoseEvent].self
                ) ?? []

                saved.removeAll { $0.id == id }
                saved.sort { $0.date > $1.date }
                storage.save(saved, as: Self.file)

                broadcaster.notify(
                    AfrezzaDoseObserver.self,
                    on: processQueue
                ) {
                    $0.afrezzaDosesDidUpdate(saved)
                }
            }
        }
    }

    private func allUnlocked() -> [AfrezzaDoseEvent] {
        storage.retrieve(
            Self.file,
            as: [AfrezzaDoseEvent].self
        )?
            .sorted { $0.date > $1.date } ?? []
    }
}
