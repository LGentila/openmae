import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// The device that has the conversation brings its own barge-in profile (`DeviceKind.bargeIn`): an iPhone's echo is
/// louder than the Mac's. A LinkHost in front of the real conversation logic (`VoicePipeline`, on stages without
/// models), the devices' sessions over memory (the rig of HeldAnnouncementTests).
@Suite("Barge-in on the device that has the conversation", .serialized)
struct BargeInProfileTests {
    @Test func theIPhoneHasItsOwnProfileAndTheMacGetsItsOwnBack() async throws {
        let rig = try await Rig()
        _ = await rig.connect()
        #expect(await rig.engine.pipeline.config.bargeIn == .mac)
        await rig.takeTheConversation()
        #expect(rig.engine.bargeInProfiles == [DeviceKind.iPhone.bargeIn])
        #expect(await rig.engine.pipeline.config.bargeIn == DeviceKind.iPhone.bargeIn)
        #expect(DeviceKind.iPhone.bargeIn != .mac)
        await rig.host.takeBack()
        await waitFor { rig.engine.localRoutes == 1 }
        #expect(await rig.engine.pipeline.config.bargeIn == .mac)
        await rig.end()
    }

    /// Not measured on an iPad yet: as before, the Mac's.
    @Test func anIPadKeepsTheMacsProfile() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        _ = await rig.connect(iPad)
        iPad.takeTheConversation()
        await waitFor { rig.engine.remoteRoutes == 1 }
        #expect(rig.engine.bargeInProfiles == [.mac])
        #expect(await rig.engine.pipeline.config.bargeIn == .mac)
        await rig.end(iPad)
    }

    /// Maé speaks on the iPhone. Her echo in its microphone, as loud as it was on 2026-10-18 (-33 dB), does not stop
    /// her; the user's voice does.
    @Test func herEchoInTheIPhoneDoesNotStopHerTheUsersVoiceDoes() async throws {
        let rig = try await Rig()
        let iPhone = await rig.connect()
        await rig.takeTheConversation()
        iPhone.phone.hold()  // her voice is still heard on the iPhone
        await rig.ringTheTimer()
        await waitFor { iPhone.phone.heardWhole.count == 1 }
        rig.phone.microphoneTone(amplitude: 0.0447)  // a tone's level is 3 dB under its peak's: -33 dB
        rig.engine.iPhoneUserSpeaks(true)
        try await Task.sleep(for: .milliseconds(700))
        rig.engine.iPhoneUserSpeaks(false)
        rig.phone.microphoneTone(amplitude: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.engine.interruptions == 0)
        #expect(iPhone.phone.stops.isEmpty)
        rig.phone.microphoneTone(amplitude: 0.3)  // -13 dB: the user
        rig.engine.iPhoneUserSpeaks(true)
        await waitFor { rig.engine.interruptions == 1 }
        rig.engine.iPhoneUserSpeaks(false)
        rig.phone.microphoneTone(amplitude: 0)
        #expect(rig.engine.interruptions == 1)
        iPhone.phone.release()
        await rig.end()
    }
}
