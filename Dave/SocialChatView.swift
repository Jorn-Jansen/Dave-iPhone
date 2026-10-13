import AVKit
import PhotosUI
import SwiftUI
import UIKit

/// One chat: the messages (yours on the right) with photos, videos, voice messages and files; hold a message to react;
/// the dots while your friend types; and a box to write, a + for photos and files, and 🎤 for a voice message.
struct ChatView: View {
    @ObservedObject private var chat = SocialChat.shared
    let code: String
    @State private var typed = ""
    @State private var problem: String?
    @State private var sending = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFile = false
    @State private var shown: URL? // a photo opened full screen
    @State private var replying: SocialChat.Line? // what you send next replies to this
    @State private var jumpTo: UUID?   // a message to scroll to (tapping a reply's quote)
    @State private var flashing: UUID? // and to light up for a moment
    @StateObject private var recorder = VoiceNoteRecorder()
    private let settings = Settings.shared
    private static let reactions = ["👍", "❤️", "😂", "😮", "😢", "🔥"]

    private var friend: SocialChat.Friend? { chat.friends.first { $0.code == code } }
    private var lines: [SocialChat.Line] { chat.chats[code] ?? [] }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if friend?.key.isEmpty ?? true { // only a warning; encrypted is simply how it is
                                Text(settings.say("⚠️ Not encrypted yet: they need the latest Dave", "⚠️ Nog niet versleuteld: ze hebben de nieuwste Dave nodig"))
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            if lines.isEmpty {
                                Text(settings.say("No messages yet. Say hi!", "Nog geen berichten. Zeg hoi!")).foregroundStyle(.secondary).padding(.top, 40)
                            }
                            ForEach(lines) { line in message(line).id(line.id) }
                            if chat.isTyping(code) { TypingDots().id("typing") }
                            if let problem { Text("⚠️ " + problem).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
                        }
                        .padding(16)
                    }
                    .onAppear { scrollDown(scroll) }
                    .onChange(of: lines.count) { _ in withAnimation { scrollDown(scroll) } }
                    .onChange(of: chat.isTyping(code)) { _ in withAnimation { scrollDown(scroll) } }
                    .onChange(of: jumpTo) { target in
                        guard let target else { return }
                        withAnimation { scroll.scrollTo(target, anchor: .center) }
                        flashing = target
                        jumpTo = nil
                        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); withAnimation { flashing = nil } }
                    }
                }
                if let replying { replyBar(replying) }
                composer
            }
        }
        .navigationTitle(friend?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { chat.markRead(code) }
        .onChange(of: lines.count) { _ in chat.markRead(code) } // you're looking at it
        .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos, maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .onChange(of: pickedPhotos) { items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { for item in items { await sendPicked(item) } }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            guard let url = try? result.get() else { return }
            Task { await sendFile(at: url) }
        }
        .sheet(item: $shown) { url in PhotoView(url: url) }
    }

    private func message(_ line: SocialChat.Line) -> some View {
        HStack {
            if line.mine { Spacer(minLength: 50) }
            VStack(alignment: line.mine ? .trailing : .leading, spacing: 4) {
                if let target = line.replyTo { quote(target) }
                content(line)
                Text(line.at).font(.caption2).opacity(0.6).padding(.horizontal, line.kind == nil ? 0 : 6)
            }
            .padding(line.kind == "photo" || line.kind == "video" ? 6 : 12)
            .background(line.mine
                        ? AnyShapeStyle(LinearGradient(colors: [.davePurple.opacity(0.85), .daveViolet.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(.ultraThinMaterial),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: line.mine ? .bottomLeading : .bottomTrailing) { reactionChip(line) }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.daveCyan, lineWidth: flashing == line.id ? 2.5 : 0)
                        .shadow(color: .daveCyan, radius: flashing == line.id ? 12 : 0))
            .contextMenu { menu(line) }
            if !line.mine { Spacer(minLength: 50) }
        }
    }

    @ViewBuilder private func reactionChip(_ line: SocialChat.Line) -> some View {
        let reactions = Array(Set([line.theirReaction, line.myReaction].compactMap { $0 })).sorted()
        if !reactions.isEmpty {
            Text(reactions.joined()).font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(x: line.mine ? -6 : 6, y: 12)
        }
    }

    @ViewBuilder private func menu(_ line: SocialChat.Line) -> some View {
        if line.msgId != nil && !(friend?.key.isEmpty ?? true) {
            Button { replying = line } label: { Label(settings.say("Reply", "Beantwoorden"), systemImage: "arrowshape.turn.up.left") }
        }
        if line.msgId != nil && !(friend?.key.isEmpty ?? true) {
            ForEach(Self.reactions, id: \.self) { emoji in
                Button(emoji + (line.myReaction == emoji ? " ✓" : "")) { Task { await chat.react(emoji, to: line, of: code) } }
            }
        }
        if let url = SocialChat.url(of: line) {
            ShareLink(item: url) { Label(settings.say("Share or save", "Delen of bewaren"), systemImage: "square.and.arrow.up") }
        }
        if line.kind == nil {
            Button { UIPasteboard.general.string = line.text } label: { Label(settings.say("Copy", "Kopiëren"), systemImage: "doc.on.doc") }
        }
    }

    @ViewBuilder private func content(_ line: SocialChat.Line) -> some View {
        if let kind = line.kind {
            if let url = SocialChat.url(of: line) {
                switch kind {
                case "photo":
                    if let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .onTapGesture { shown = url }
                    }
                case "video":
                    VideoPlayer(player: AVPlayer(url: url)).frame(width: 240, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                case "voice":
                    VoiceNotePlayer(url: url)
                default:
                    ShareLink(item: url) { Label(line.name ?? "file", systemImage: "doc.fill").foregroundStyle(.white) }
                }
            } else {
                Text(line.failed == true
                     ? "⚠️ " + settings.say("This file couldn't be fetched (files are kept for 3 days)", "Dit bestand kon niet worden opgehaald (bestanden blijven 3 dagen bewaard)")
                     : "⏳ " + line.text)
                    .font(.callout)
            }
        } else {
            Text(line.text).textSelection(.enabled)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Menu {
                Button { pickingPhotos = true } label: { Label(settings.say("Photo or video", "Foto of video"), systemImage: "photo.on.rectangle") }
                Button { pickingFile = true } label: { Label(settings.say("File", "Bestand"), systemImage: "doc") }
            } label: {
                Image(systemName: "plus").font(.headline).foregroundStyle(.white).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            TextField(placeholder, text: $typed)
                .submitLabel(.send).onSubmit(send)
                .disabled(recorder.recording)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .onChange(of: typed) { text in if !text.isEmpty { Task { await chat.sendTyping(to: code) } } }
            if !typed.isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.headline.bold()).foregroundStyle(.white).frame(width: 40, height: 40)
                        .background(LinearGradient(colors: [.davePurple, .davePink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                }
            } else {
                Button(action: toggleRecording) {
                    Image(systemName: recorder.recording ? "stop.fill" : "mic.fill").font(.headline).foregroundStyle(.white).frame(width: 40, height: 40)
                        .background(recorder.recording ? AnyShapeStyle(Color.red)
                                                       : AnyShapeStyle(LinearGradient(colors: [.davePurple, .davePink], startPoint: .topLeading, endPoint: .bottomTrailing)),
                                    in: Circle())
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// A small version of the message a reply is about; tap it to see that message.
    @ViewBuilder private func quote(_ target: String) -> some View {
        let original = lines.first { $0.msgId == target }
        Button { if let original { jumpTo = original.id } } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.up.right").font(.caption2)
                if let original { Text(original.mine ? settings.say("You", "Jij") : friend?.name ?? "").font(.caption.bold()) }
                Text(original.map(snippet) ?? settings.say("a message that's no longer here", "een bericht dat er niet meer is")).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: 230, alignment: .leading)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(Color.daveCyan.opacity(0.8)).frame(width: 2) }
            .opacity(0.85)
        }
        .buttonStyle(.plain)
    }

    /// "Replying to Alex: …" above the box, with ✕.
    private func replyBar(_ line: SocialChat.Line) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left").font(.caption)
            Text(settings.say("Replying to", "Antwoord op")).font(.caption)
            Text(line.mine ? settings.say("You", "Jij") : friend?.name ?? "").font(.caption.bold())
            Text(snippet(line)).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Spacer()
            Button { replying = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 6)
    }

    private func snippet(_ line: SocialChat.Line) -> String { line.text.count > 90 ? String(line.text.prefix(90)) + "…" : line.text }

    private var placeholder: String {
        if recorder.recording { return settings.say("🎤 Recording… tap ■ to send", "🎤 Opnemen… tik ■ om te versturen") }
        if sending { return settings.say("Sending…", "Versturen…") }
        return settings.say("Message…", "Bericht…")
    }

    private func scrollDown(_ scroll: ScrollViewProxy) {
        if chat.isTyping(code) { scroll.scrollTo("typing", anchor: .bottom) }
        else if let last = lines.last { scroll.scrollTo(last.id, anchor: .bottom) }
    }

    private func send() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        let reply = replying?.msgId
        replying = nil
        Task { problem = await chat.send(text, to: code, reply: reply, settings: settings) }
    }

    /// 🎤: tap to start, tap ■ to stop and send.
    private func toggleRecording() {
        if recorder.recording {
            guard let file = recorder.stop(), let data = try? Data(contentsOf: file) else { return }
            Task { await sendData(data, name: "Voice message.m4a", kind: "voice") }
        } else {
            Task { if !(await recorder.start()) { problem = settings.say("I'm not allowed to use the microphone.", "Ik mag de microfoon niet gebruiken.") } }
        }
    }

    private func sendPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            problem = settings.say("That photo couldn't be loaded.", "Die foto kon niet worden geladen.")
            return
        }
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        await sendData(data, name: (isVideo ? "Video." : "Photo.") + ext, kind: isVideo ? "video" : "photo")
    }

    private func sendFile(at url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            problem = settings.say("That file couldn't be read.", "Dat bestand kon niet worden gelezen.")
            return
        }
        await sendData(data, name: url.lastPathComponent, kind: nil)
    }

    private func sendData(_ data: Data, name: String, kind: String?) async {
        sending = true
        let reply = replying?.msgId
        replying = nil
        problem = await chat.sendFile(data, name: name, kind: kind, to: code, reply: reply, settings: settings)
        sending = false
    }
}

/// A photo full screen, to look at or share.
private struct PhotoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Settings.shared.say("Close", "Sluiten")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
            }
        }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

/// "…" while your friend is typing: three dots that bounce.
private struct TypingDots: View {
    var body: some View {
        HStack {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        let hop = max(0, sin(t * 6 - Double(i) * 0.8))
                        Circle().fill(Color.white.opacity(0.45 + 0.5 * hop)).frame(width: 7, height: 7).offset(y: -5 * hop)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Spacer()
        }
    }
}

/// A voice message: play/pause, a bar that fills while it plays, and the time left.
private struct VoiceNotePlayer: View {
    let url: URL
    @StateObject private var player = VoiceNotePlayback()

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle(url) } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.callout).foregroundStyle(.white).frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [.davePurple, .davePink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            }
            .buttonStyle(.borderless)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(LinearGradient(colors: [.daveCyan, .davePink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * player.progress)
                }
            }
            .frame(width: 130, height: 6)
            Text(player.timeLeft).font(.caption.monospacedDigit()).opacity(0.75)
        }
        .onAppear { player.load(url) }
        .onDisappear { player.stop() }
    }
}

@MainActor
private final class VoiceNotePlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var progress: CGFloat = 0
    @Published var timeLeft = "0:00"
    private var audio: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        guard audio == nil else { return }
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.delegate = self
        timeLeft = Self.time(audio?.duration ?? 0)
    }

    func toggle(_ url: URL) {
        load(url)
        guard let audio else { return }
        if audio.isPlaying {
            audio.pause()
            playing = false
            timer?.invalidate()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        audio.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let audio = self.audio, audio.duration > 0 else { return }
                self.progress = CGFloat(audio.currentTime / audio.duration)
                self.timeLeft = Self.time(audio.duration - audio.currentTime)
            }
        }
    }

    func stop() {
        audio?.stop()
        playing = false
        timer?.invalidate()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let duration = player.duration
        Task { @MainActor in
            self.playing = false
            self.progress = 0
            self.timer?.invalidate()
            self.timeLeft = Self.time(duration)
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Records a voice message (AAC, like voice notes everywhere) until you tap stop.
@MainActor
final class VoiceNoteRecorder: ObservableObject {
    @Published var recording = false
    private var recorder: AVAudioRecorder?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-message.m4a")

    func start() async -> Bool {
        let allowed = await withCheckedContinuation { done in AVAudioSession.sharedInstance().requestRecordPermission { done.resume(returning: $0) } }
        guard allowed else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            try? FileManager.default.removeItem(at: file)
            let r = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1,
                                                             AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            guard r.record(forDuration: 120) else { return false } // two minutes at most
            recorder = r
            recording = true
            return true
        } catch { return false }
    }

    func stop() -> URL? {
        guard let r = recorder else { return nil }
        let length = r.currentTime
        r.stop()
        recorder = nil
        recording = false
        ThemeSounds.play(.heard)
        return length > 0.5 ? file : nil
    }
}
