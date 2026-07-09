import Foundation

extension DaemonCore {
    public func guiProbe(_ req: GuiRuntimeReq) throws -> GuiProbeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        return try target.control.guiProbe(target.runtime)
    }

    public func guiStart(_ req: GuiRuntimeReq) throws -> GuiRuntimeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        return try target.control.guiStart(target.runtime)
    }

    public func guiStatus(_ req: GuiRuntimeReq) throws -> GuiRuntimeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        return try target.control.guiStatus(target.runtime)
    }

    public func guiStop(_ req: GuiRuntimeReq) throws -> GuiRuntimeData {
        beginOp()
        defer { endOp() }
        let target = try guiTarget(req)
        return try target.control.guiStop(target.runtime)
    }

    public func guiLaunch(_ req: GuiLaunchReq) throws -> ExecData {
        beginOp()
        defer { endOp() }
        let entry = try ensureUp(req.distro)
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let launch = GuiLaunchReq(
            distro: entry.name, user: req.user, argv: req.argv, env: req.env, cwd: req.cwd)
        return try control.guiLaunch(launch)
    }

    private struct GuiTarget {
        let control: ControlClient
        let runtime: GuiRuntimeReq
    }

    private func guiTarget(_ req: GuiRuntimeReq) throws -> GuiTarget {
        let entry = try ensureUp(req.distro)
        guard let control = withLock({ self.control }) else {
            throw MSLError.configuration("VM not running")
        }
        let runtime = GuiRuntimeReq(distro: entry.name, user: req.user)
        return GuiTarget(control: control, runtime: runtime)
    }
}
