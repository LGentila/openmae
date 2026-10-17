import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// An iPad left at home as a station: what Maé says on her own (a timer that rings) is spoken on it when it is
/// connected, wherever the conversation is; otherwise where it was spoken before. A LinkHost in front of the real
/// conversation logic (`VoicePipeline`, on stages without models), the devices' sessions over memory (the rig of
/// HeldAnnouncementTests).
@Suite("Announcements on the home station", .serialized)
struct StationAnnouncementTests {
    static let sentence = HeldAnnouncementTests.sentence

    /// The conversation is on the Mac: the timer rings on the station only, and the Mac keeps its microphone.
    @Test func onTheStationWhileTheMacHasTheConversation() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let station = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        await rig.ringTheTimer()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(station.phone.played.map(\.frames) == [Rig.announcementFrames])
        #expect(rig.engine.stationPlayed == Rig.announcementSamples)
        #expect(rig.engine.localPlayed == 0)  // nothing on the Mac's speakers
        #expect(rig.engine.remoteRoutes == 0)  // the Mac kept its microphone and the conversation
        #expect(rig.engine.localRoutes == 0)
        await rig.end(iPad)
    }

    /// The iPhone is away with the conversation: the timer rings on the station, the iPhone keeps the conversation.
    @Test func onTheStationWhileTheIPhoneHasTheConversation() async throws {
        let rig = try await Rig()
        let iPhone = await rig.connect()
        await rig.takeTheConversation()
        let iPad = FakePhone.iPad()
        let station = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        await rig.ringTheTimer()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(station.phone.played.map(\.frames) == [Rig.announcementFrames])
        #expect(iPhone.phone.framesHeard == 0)
        #expect(rig.engine.remotePlayed == 0)  // nothing through the conversation's output
        #expect(rig.engine.remoteRoutes == 1)  // the iPhone still has the conversation
        #expect(rig.engine.localRoutes == 0)
        await rig.end(iPad)
    }

    /// The station has the conversation: the announcement is spoken there like an answer.
    @Test func likeAnAnswerWhenTheStationHasTheConversation() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let station = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        iPad.takeTheConversation()
        await waitFor { rig.engine.remoteRoutes == 1 && rig.engine.announcements == [true, nil] }
        #expect(rig.engine.announcements == [true, nil])
        await rig.ringTheTimer()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(station.phone.played.map(\.frames) == [Rig.announcementFrames])
        #expect(rig.engine.remotePlayed == Rig.announcementSamples)
        #expect(rig.engine.stationPlayed == 0)
        await rig.end(iPad)
    }

    /// No station connected (an iPad that is not one, or no longer): as before, where the conversation is.
    @Test func asBeforeWithoutAStation() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let tablet = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        iPad.say(station: false)  // unplugged
        await waitFor { rig.engine.announcements == [true, nil] }
        await rig.ringTheTimer()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.localPlayed == Rig.announcementSamples)
        #expect(rig.engine.stationPlayed == 0)
        #expect(tablet.phone.framesHeard == 0)
        await rig.end(iPad)
    }

    /// Two stations: the most recently used one speaks.
    @Test func onTheMostRecentlyUsedStation() async throws {
        let rig = try await Rig()
        let kitchen = FakePhone(key: Data(repeating: 12, count: 32), model: "iPad16,1")
        let livingRoom = FakePhone.iPad()
        let first = await rig.connect(kitchen)
        kitchen.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        let second = await rig.connect(livingRoom)
        livingRoom.say(station: true)
        await waitFor { rig.engine.announcements == [true, true] }  // the newest one
        // The kitchen's is used: a tap there (and the talk key let go at once).
        var taps = TapToTalk()
        first.phone.session.send(.command(taps.tap()))
        await waitFor { rig.engine.remoteRoutes == 1 }
        first.phone.session.send(.command(taps.tap()))
        first.phone.session.send(.audio(.stop))
        await waitFor { rig.engine.localRoutes == 1 }
        await rig.ringTheTimer()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(first.phone.played.map(\.frames) == [Rig.announcementFrames])
        #expect(second.phone.framesHeard == 0)
        await rig.end(kitchen, livingRoom)
    }

    /// The station's connection drops: within the grace period the announcement waits for it, and is spoken on it
    /// once it is back, by another way.
    @Test func waitsForTheStationWithinItsGrace() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let first = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        first.wire.close()
        await waitFor { rig.engine.announcements == [true, false] }
        #expect(rig.engine.announcements == [true, false])
        await rig.ringTheTimer()
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.engine.said.isEmpty)
        #expect(rig.engine.localPlayed == 0)
        #expect(rig.engine.stationPlayed == 0)
        let second = await rig.connect(iPad, path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [Rig.announcementFrames])
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.announcements == [true, false, true])
        #expect(rig.engine.localPlayed == 0)
        #expect(first.phone.framesHeard == 0)
        await rig.end(iPad)
    }

    /// It does not come back: at the end of its grace period the announcement is spoken on the Mac.
    @Test func onTheMacOnceTheStationsGraceIsOver() async throws {
        let rig = try await Rig(gracePeriod: .milliseconds(800))
        let iPad = FakePhone.iPad()
        let first = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        first.wire.close()
        await waitFor { rig.engine.announcements == [true, false] }
        await rig.ringTheTimer()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.engine.said.isEmpty)  // still its time to come back
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        #expect(rig.engine.announcements == [true, false, nil])
        #expect(rig.engine.localPlayed == Rig.announcementSamples)
        #expect(rig.engine.stationPlayed == 0)
        #expect(first.phone.framesHeard == 0)
        await rig.end(iPad)
    }

    /// The iPad sits next to the Mac: while the announcement plays on it, the Mac's microphone hears Maé's voice. It
    /// does not take it for the user's.
    @Test func theMacsMicrophoneDoesNotInterruptTheStation() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let station = await rig.connect(iPad)
        iPad.say(station: true)
        await waitFor { rig.engine.announcements == [true] }
        station.phone.hold()  // the voice is still being heard on the iPad
        await rig.ringTheTimer()
        await waitFor { station.phone.heardWhole.count == 1 }
        await rig.engine.macMicrophoneHearsSpeech(seconds: 0.6)
        #expect(rig.engine.interruptions == 0)
        #expect(station.phone.stops.isEmpty)
        station.phone.release()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(rig.engine.said == [Self.sentence])
        await rig.end(iPad)
    }

    /// The same voice on the Mac's speakers, without a station: the Mac's microphone interrupts it as before (the
    /// rule above is the station's only).
    @Test func withoutAStationTheMacsMicrophoneInterruptsAsBefore() async throws {
        let rig = try await Rig()
        rig.engine.speakers.hold()
        await rig.ringTheTimer()
        await waitFor { rig.engine.localPlayed == Rig.announcementSamples }
        await rig.engine.macMicrophoneHearsSpeech(seconds: 0.6)
        await waitFor { rig.engine.interruptions == 1 }
        #expect(rig.engine.interruptions == 1)
        rig.engine.speakers.release()
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.engine.said.isEmpty)  // cut off: never said to the end
        await rig.end()
    }

    /// A minute after an exchange in "Tap to talk" the station gives the conversation back (`audio stop`) and stays
    /// linked: the Mac has its microphone again, and the next timer rings on the station.
    @Test func theStationGivesTheConversationBackAndStaysLinked() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let station = await rig.connect(iPad)
        iPad.say(station: true)
        iPad.takeTheConversation()
        await waitFor { rig.engine.remoteRoutes == 1 }
        iPad.giveTheConversationBack()
        await waitFor { rig.engine.localRoutes == 1 && rig.engine.announcements == [true, nil, true] }
        #expect(rig.engine.localRoutes == 1)
        #expect(rig.engine.announcements == [true, nil, true])
        #expect(station.phone.session.isOpen)
        await rig.ringTheTimer()
        await waitFor { rig.engine.said == [Self.sentence] }
        #expect(station.phone.played.map(\.frames) == [Rig.announcementFrames])
        #expect(rig.engine.stationPlayed == Rig.announcementSamples)
        #expect(rig.engine.localPlayed == 0)
        await rig.end(iPad)
    }

    /// Tap to talk, from the station: the first tap gives it the conversation and presses the talk key, the second
    /// releases it, as ⌥ Space on the Mac.
    @Test func twoTapsPressThenReleaseTheTalkKey() async throws {
        let rig = try await Rig()
        let iPad = FakePhone.iPad()
        let station = await rig.connect(iPad)
        iPad.say(station: true)
        var taps = TapToTalk()
        station.phone.session.send(.command(taps.tap()))
        await waitFor { rig.engine.remoteRoutes == 1 && rig.engine.commands.count == 1 }
        station.phone.session.send(.command(taps.tap()))
        await waitFor { rig.engine.commands.count == 2 }
        #expect(rig.engine.commands == [.talkKey(pressed: true), .talkKey(pressed: false)])
        #expect(rig.engine.remoteRoutes == 1)  // the first tap gave it the conversation
        await rig.end(iPad)
    }
}

@Suite("Talking from an iPhone or an iPad")
struct DeviceTalkTests {
    @Test func twoTapsGiveTalkKeyTrueThenFalse() {
        var taps = TapToTalk()
        #expect(taps.tap() == .talkKey(pressed: true))
        #expect(taps.isPressed)
        #expect(taps.tap() == .talkKey(pressed: false))
        #expect(!taps.isPressed)
        #expect(taps.tap() == .talkKey(pressed: true))
        taps.reset()  // the Mac answered: the next tap talks again
        #expect(taps.tap() == .talkKey(pressed: true))
        #expect(LinkMessage.command(.talkKey(pressed: true)).encoded.count > 0)
    }

    /// A station gives the conversation back one minute after an exchange in "Tap to talk" or "Hold", never in
    /// hands-free; elsewhere, after the "Automatic end" setting.
    @Test func theStationGivesTheConversationBackAfterAMinuteInTapMode() {
        #expect(ConversationRelease.delay(station: true, mode: .tap, autoEndMinutes: 10) == .seconds(60))
        #expect(ConversationRelease.delay(station: true, mode: .hold, autoEndMinutes: 0) == .seconds(60))
        #expect(ConversationRelease.delay(station: true, mode: .handsFree, autoEndMinutes: 2) == nil)
        #expect(ConversationRelease.delay(station: false, mode: .tap, autoEndMinutes: 2) == .seconds(120))
        #expect(ConversationRelease.delay(station: false, mode: .handsFree, autoEndMinutes: 0) == nil)
        #expect(DeviceTalkMode.tap.listening == .pushToTalk)
        #expect(DeviceTalkMode.hold.listening == .pushToTalk)
        #expect(DeviceTalkMode.handsFree.listening == .handsFree)
    }

    @Test func deviceMessageEncodesAndDecodes() throws {
        let json = try JSONSerialization.jsonObject(with: LinkMessage.device(station: true).encoded) as? [String: Any]
        #expect(json?["type"] as? String == "device")
        #expect(json?["station"] as? Bool == true)
        for station in [true, false] {
            guard case .device(let decoded) = try LinkMessage(decoding: LinkMessage.device(station: station).encoded)
            else {
                Issue.record("not a device message")
                continue
            }
            #expect(decoded == station)
        }
        guard case .device(false) = try LinkMessage(decoding: Data(#"{"type":"device","station":false}"#.utf8)) else {
            Issue.record("not decoded")
            return
        }
    }

    /// A Mac from before the station does not list the `device` message in its handshake: the iPad does not send it
    /// (that Mac would close the session on it). One that lists it gets it.
    @Test func anOldMacIsNotSentTheDeviceMessage() throws {
        let old = try JSONDecoder().decode(HandshakePayload.Mac.self, from: Data(#"{"name":"Mac de test"}"#.utf8))
        #expect(old.features == nil)
        #expect(PhoneLink.deviceMessage(station: true, to: old) == nil)
        #expect(PhoneLink.deviceMessage(station: true, to: nil) == nil)
        let new = HandshakePayload.Mac(name: "Mac de test", features: [LinkMessage.deviceFeature])
        let sent = try JSONDecoder().decode(HandshakePayload.Mac.self, from: HandshakePayload.encode(new))
        guard case .device(true)? = PhoneLink.deviceMessage(station: true, to: sent) else {
            Issue.record("no device message for a Mac that understands it")
            return
        }
        #expect(PhoneLink.deviceMessage(station: nil, to: sent) == nil)  // an iPhone says nothing
    }

    /// From now on a Mac (or a device) skips a message of a kind it does not know, sent by a newer peer, and the
    /// session goes on.
    @Test func aMessageOfAnUnknownKindIsIgnored() async throws {
        let toMac = SymmetricKey(size: .bits256)
        let toPhone = SymmetricKey(size: .bits256)
        let line = RawLine()
        let mac = LinkSession(transport: line.mac, inbox: FrameInbox(line.mac),
                              keys: SessionKeys((send: NoiseCipher(key: toPhone), receive: NoiseCipher(key: toMac))),
                              peerKey: Data(repeating: 11, count: 32), peerMac: nil)
        var phone = NoiseCipher(key: toMac)
        line.toMac(Frame.encode(try phone.encrypt(Data(#"{"type":"future","what":1}"#.utf8))))
        line.toMac(Frame.encode(try phone.encrypt(LinkMessage.device(station: true).encoded)))
        var received: LinkMessage?
        for await message in mac.messages {
            received = message
            break
        }
        guard case .device(true)? = received else {
            Issue.record("the message after the unknown one was not received")
            return
        }
        #expect(mac.isOpen)
        mac.close()
    }

    @Test func iPadsAreRecognised() {
        let mini = PairedDevice(publicKey: Data(repeating: 3, count: 32), name: "iPad", model: "iPad14,1")
        #expect(mini.kind == .iPad)
        #expect(mini.displayName == "iPad mini 6")
        #expect(PairedDevice(publicKey: Data(repeating: 4, count: 32), name: "iPad", model: "iPad14,2").displayName
            == "iPad mini 6")
        let phone = PairedDevice(publicKey: Data(repeating: 5, count: 32), name: "iPhone", model: "iPhone17,3")
        #expect(phone.kind == .iPhone)
        #expect(phone.displayName == "iPhone 16")
        // An iPad not listed yet keeps the name it gave.
        #expect(PairedDevice(publicKey: Data(repeating: 6, count: 32), name: "iPad", model: "iPad99,9").displayName
            == "iPad")
    }
}

/// One end of a connection whose other end the test writes to directly.
private final class RawLine: @unchecked Sendable {
    let mac: RawEnd
    init() { mac = RawEnd() }
    func toMac(_ bytes: Data) { mac.receive(bytes) }

    final class RawEnd: LinkTransport, @unchecked Sendable {
        let path = LinkPath.direct
        let incoming: AsyncStream<TransportInput>
        private let sink: AsyncStream<TransportInput>.Continuation

        init() {
            (incoming, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        }

        func receive(_ bytes: Data) { sink.yield(.bytes(bytes)) }
        func send(_ bytes: Data) {}
        func sendDatagram(_ datagram: Data) {}
        func close() {
            sink.yield(.closed(nil))
            sink.finish()
        }
    }
}
