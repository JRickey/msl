import ArgumentParser
import Foundation
import MSLCore

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the daemon's VM state and each distro's state and sessions.")

    func run() throws {
        let home = MSLHome.resolve()
        guard DaemonClient.isRunning(home) else {
            print("daemon not running")
            return
        }
        let status = try DaemonClient.status(home)
        let idle = status.idleTimeoutS == 0 ? "never" : "\(status.idleTimeoutS)s"
        print("VM: \(status.vm)    idle-timeout: \(idle)")
        printMemory(status.memory)
        printForwards(status.forwardedPorts)
        guard !status.distros.isEmpty else {
            print("no distros installed (use 'msl install')")
            return
        }
        print("NAME              STATE         SESSIONS")
        for entry in status.distros {  // bounded: registry list
            print(pad(entry.name, 18) + pad(entry.state, 14) + "\(entry.sessions)")
        }
        printGui(status.gui)
    }

    private func printGui(_ runtimes: [GuiRuntimeStatus]?) {
        guard let runtimes, !runtimes.isEmpty else { return }
        print("GUI:")
        for runtime in runtimes {  // bounded: GuiRuntimeTable.maxRuntimes
            print("  " + guiLine(runtime))
        }
    }

    private func guiLine(_ runtime: GuiRuntimeStatus) -> String {
        var fields = ["\(runtime.distro)/\(runtime.user)", runtime.state]
        if let pid = runtime.pid { fields.append("pid=\(pid)") }
        fields.append("wayland=\(runtime.waylandDisplay)")
        if let x11 = runtime.x11Display { fields.append("x11=\(x11)") }
        fields.append("presenters=\(runtime.presenters)")
        fields.append("windows=\(runtime.windows)")
        if let error = runtime.lastError, !error.isEmpty { fields.append("error=\(error)") }
        return fields.joined(separator: " ")
    }

    private func printMemory(_ memory: MemoryStatus?) {
        guard let memory else { return }
        print(
            "memory: target \(memory.targetMiB) MiB / max \(memory.maxMiB) MiB "
                + "(available \(memory.availableMiB) MiB)")
    }

    private func printForwards(_ ports: [UInt16]?) {
        guard let ports, !ports.isEmpty else { return }
        print("forwards: " + ports.map(String.init).joined(separator: ", "))
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }
}
