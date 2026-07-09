import Foundation
import XCTest

@testable import MSLCore

final class ProtoV3Tests: XCTestCase {
    func testVersionIsFive() {
        XCTAssertEqual(Proto.version, 5)
        XCTAssertEqual(Proto.forwardPort, 5003)
    }

    func testDistroUpReqEncodesRosetta() throws {
        let req = DistroUpReq(
            name: "ubuntu", dev: "/dev/vda", hostname: "ubuntu", macShare: true, rosetta: true)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"rosetta\":true"), json)
        XCTAssertTrue(json.contains("\"mac_share\":true"), json)
    }

    func testDistroUpReqEncodesRosettaFalse() throws {
        let req = DistroUpReq(
            name: "ubuntu", dev: "/dev/vda", hostname: "ubuntu", macShare: false, rosetta: false)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"rosetta\":false"), json)
    }

    func testMemStatsDecodesWithPSI() throws {
        let text =
            #"{"mem_total_kib":16307840,"mem_available_kib":12094432,"swap_total_kib":0,"#
            + #""swap_free_kib":0,"psi_some_avg10":1.5,"psi_full_avg10":0.25}"#
        let stats = try JSONDecoder().decode(MemStatsData.self, from: Data(text.utf8))
        XCTAssertEqual(stats.memTotalKiB, 16_307_840)
        XCTAssertEqual(stats.memAvailableKiB, 12_094_432)
        XCTAssertEqual(stats.psiSomeAvg10, 1.5)
        XCTAssertEqual(stats.psiFullAvg10, 0.25)
    }

    func testMemStatsDecodesWithoutPSI() throws {
        let json = Data(
            #"{"mem_total_kib":100,"mem_available_kib":50,"swap_total_kib":0,"swap_free_kib":0}"#
                .utf8)
        let stats = try JSONDecoder().decode(MemStatsData.self, from: json)
        XCTAssertNil(stats.psiSomeAvg10)
        XCTAssertNil(stats.psiFullAvg10)
        XCTAssertEqual(stats.memAvailableKiB, 50)
    }

    func testNetListenersDecodes() throws {
        let json = Data(#"{"ports":[22,3000,8080]}"#.utf8)
        let listeners = try JSONDecoder().decode(NetListenersData.self, from: json)
        XCTAssertEqual(listeners.ports, [22, 3000, 8080])
    }

    func testGuiRuntimeReqEncodesDistroAndUser() throws {
        let req = GuiRuntimeReq(distro: "ubuntu", user: "root")
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"distro\":\"ubuntu\""), json)
        XCTAssertTrue(json.contains("\"user\":\"root\""), json)
    }

    func testGuiLaunchReqEncodesScopedLaunch() throws {
        let req = GuiLaunchReq(
            distro: "ubuntu", argv: ["/usr/bin/gedit"], env: ["WAYLAND_DISPLAY": "msl-way-0"],
            cwd: "/tmp")
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"argv\":[\"\\/usr\\/bin\\/gedit\"]"), json)
        XCTAssertTrue(json.contains("\"cwd\":\"\\/tmp\""), json)
        XCTAssertTrue(json.contains("\"WAYLAND_DISPLAY\":\"msl-way-0\""), json)
    }

    func testGuiProbeDecodes() throws {
        let text =
            #"{"runtime":{"state":"running","runtime_dir":"/tmp/msl-gui-0","#
            + #""wayland_display":"msl-way-0","socket_present":true,"pid":7,"#
            + #""log_tail":""},"capabilities":[{"name":"msl-way","present":true},"#
            + #"{"name":"gimp","present":false}]}"#
        let json = Data(text.utf8)
        let probe = try JSONDecoder().decode(GuiProbeData.self, from: json)
        XCTAssertEqual(probe.runtime.state, "running")
        XCTAssertEqual(probe.runtime.pid, 7)
        XCTAssertTrue(
            probe.capabilities.contains(GuiCapabilityData(name: "msl-way", present: true)))
        XCTAssertTrue(probe.capabilities.contains(GuiCapabilityData(name: "gimp", present: false)))
    }

    func testForwardHelloEncodesPort() throws {
        let data = try ForwardHello(port: 8080).encoded()
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"port\":8080"), json)
    }

    func testStatusDecodesLegacyReplyWithoutMemory() throws {
        let json = Data(
            #"{"ok":true,"data":{"vm":"running","distros":[],"idle_timeout_s":60}}"#.utf8)
        let reply = try LocalResponse<StatusData>.decode(json)
        XCTAssertEqual(reply.data?.vm, "running")
        XCTAssertNil(reply.data?.memory)
        XCTAssertNil(reply.data?.forwardedPorts)
    }

    func testStatusRoundTripsMemoryAndForwards() throws {
        let status = StatusData(
            vm: "running", distros: [], idleTimeoutS: 60,
            memory: MemoryStatus(targetMiB: 1024, maxMiB: 4096, availableMiB: 612),
            forwardedPorts: [3000, 8080])
        let reply = try LocalResponse<StatusData>.decode(try LocalReply.ok(status))
        XCTAssertEqual(reply.data, status)
        let json = try XCTUnwrap(String(bytes: LocalReply.ok(status), encoding: .utf8))
        XCTAssertTrue(json.contains("\"target_mib\""), json)
        XCTAssertTrue(json.contains("\"forwarded_ports\""), json)
    }
}
