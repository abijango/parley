import Combine
import Foundation

/// Caches the joined people model so list/detail derivations don't rebuild on every render.
@MainActor
final class PeopleIndex: ObservableObject {
    @Published private(set) var allPeople: [Person] = []

    private var cancellables = Set<AnyCancellable>()

    func observe(vault: VaultDirectory, voiceprints: VoiceprintStore) {
        cancellables.removeAll()
        Publishers.CombineLatest(vault.$contacts, voiceprints.$voiceprints)
            .sink { [weak self] contacts, voiceprints in
                self?.allPeople = PeopleJoin.build(contacts: contacts, voiceprints: voiceprints)
            }
            .store(in: &cancellables)
    }
}
