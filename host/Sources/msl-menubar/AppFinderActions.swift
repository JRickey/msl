import Foundation
import MSLCore

enum FinderDistroOperation: Equatable, Sendable {
    case mounting
    case unmounting
}

struct AppFinderActions: Sendable {
    typealias Mount = @Sendable (MSLHome, String) async throws -> MountEntry
    typealias Unmount = @Sendable (MSLHome, String) async throws -> MountEntry

    let mount: Mount
    let unmount: Unmount

    static let live = AppFinderActions(
        mount: { home, name in
            try await Task.detached(priority: .userInitiated) {
                try FinderMountService().mount(home: home, name: name, readOnly: false)
            }.value
        },
        unmount: { home, name in
            try await Task.detached(priority: .userInitiated) {
                try FinderMountService().unmount(home: home, name: name, force: false)
            }.value
        })
}

extension MainWindowModel {
    func openFinder() {
        guard let distro = selectedDistro else { return }
        if let path = distro.inventory.finderPath {
            revealFinderPath(path)
            return
        }
        guard finderSetupState == .ready else {
            presentedError = "Set up Finder integration before mounting \(distro.name)."
            return
        }
        mountInFinder(name: distro.name)
    }

    func unmountFromFinder() {
        guard let distro = selectedDistro, distro.inventory.finderPath != nil else { return }
        let name = distro.name
        beginFinderOperation(name: name, operation: .unmounting) { home, actions in
            _ = try await actions.unmount(home, name)
            return nil
        }
    }

    func finderOperation(for name: String) -> FinderDistroOperation? {
        guard Registry.isValidName(name) else { return nil }
        return finderOperations[name]
    }

    private func mountInFinder(name: String) {
        beginFinderOperation(name: name, operation: .mounting) { home, actions in
            let mounted = try await actions.mount(home, name)
            return mounted.mountpoint
        }
    }

    private func beginFinderOperation(
        name: String, operation: FinderDistroOperation,
        action: @escaping @Sendable (MSLHome, AppFinderActions) async throws -> String?
    ) {
        guard Registry.isValidName(name), !operationInFlight else { return }
        guard finderOperations.isEmpty else { return }
        operationInFlight = true
        finderOperations[name] = operation
        let home = self.home
        let actions = finderActions
        Task { @MainActor [weak self] in
            guard let self else { return }
            var revealPath: String?
            var serviceError: (any Error)?
            do {
                revealPath = try await action(home, actions)
            } catch {
                serviceError = error
            }
            var refreshError: (any Error)?
            do {
                try await self.refreshForFinderOperation()
            } catch {
                refreshError = error
            }
            let finished = self.finishFinderOperation(
                name: name, serviceError: serviceError, refreshError: refreshError)
            if finished, serviceError == nil, refreshError == nil, let revealPath {
                self.revealFinderPath(revealPath)
            }
        }
    }

    private func finishFinderOperation(
        name: String, serviceError: (any Error)?, refreshError: (any Error)?
    ) -> Bool {
        let operation = finderOperations.removeValue(forKey: name)
        operationInFlight = false
        guard operation != nil else {
            presentedError = "Finder action state for \(name) could not be reconciled."
            return false
        }
        assert(Registry.isValidName(name), "completed Finder operation names stay validated")
        assert(finderOperations[name] == nil, "completed Finder operation must leave idle state")
        if let serviceError, let refreshError {
            presentedError =
                "Finder action for \(name) failed: \(serviceError). "
                + "Inventory refresh also failed: \(refreshError)"
        } else if let serviceError {
            presentedError = "Finder action for \(name) failed: \(serviceError)"
        } else if let refreshError {
            presentedError =
                "Finder action completed, but inventory refresh failed: \(refreshError)"
        }
        return true
    }

    private func revealFinderPath(_ path: String) {
        guard !path.isEmpty, path.hasPrefix("/") else {
            presentedError = "Finder returned an invalid mount path."
            return
        }
        guard finderPathOpener(path) else {
            presentedError = "Finder could not open \(path)."
            return
        }
        assert(path.hasPrefix("/"), "Finder paths stay absolute")
        assert(!path.isEmpty, "Finder paths stay nonempty")
    }
}
