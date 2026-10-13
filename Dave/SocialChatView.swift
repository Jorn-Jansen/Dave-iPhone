import AVKit
import PhotosUI
import SwiftUI
import UIKit

/// One chat: the messages (yours on the right) with photos, videos, voice messages and files; hold a message to reply,
/// react, edit or delete it, or translate it; "Seen" under what they've read; the dots while your friend types; and a box
/// to write, a + for photos and files, ⏰ to send it later, and 🎤 for a voice message. 🔍 searches the chat.
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
    @State private var editing: SocialChat.Line? // what you send next replaces this message of yours
    @State private var showWords = Set<UUID>()   // voice messages showing what's said in them
    @State private var scheduling = false
    @State private var sendAt = Date().addingTimeInterval(3600)
    @State private var searching = false
    @State private var makingPoll = false
    @Environment(\.openURL) private var openURL
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
                            ForEach(chat.scheduled.filter { $0.code == code }) { later in scheduledBubble(later) }
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
                if editing != nil { editBar }
                if scheduling { scheduleBar }
                composer
            }
        }
        .navigationTitle(friend?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }
            }
        }
        .sheet(isPresented: $makingPoll) {
            PollMaker { question, answers in
                makingPoll = false
                let reply = replying?.msgId
                replying = nil
                Task { problem = await chat.sendPoll(question, options: answers, to: code, reply: reply, settings: settings) }
            }
        }
        .sheet(isPresented: $searching) {
            ChatSearch(lines: lines, friendName: friend?.name ?? "") { found in
                searching = false
                Task { try? await Task.sleep(nanoseconds: 400_000_000); jumpTo = found }
            }
        }
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
        VStack(alignment: line.mine ? .trailing : .leading, spacing: 3) {
            // a reply: a small version of the original floats just above the bubble
            if let target = line.replyTo { quote(target).padding(.horizontal, 10) }
            bubble(line)
            if line.mine, let seen = friend?.seenId, line.msgId == seen, settings.readReceipts { // they've read up to here
                Text(settings.say("Seen", "Gezien") + " " + (friend?.seenAt ?? "")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: line.mine ? .trailing : .leading)
    }

    private func bubble(_ line: SocialChat.Line) -> some View {
        HStack {
            if line.mine { Spacer(minLength: 50) }
            VStack(alignment: line.mine ? .trailing : .leading, spacing: 4) {
                content(line)
                Text(line.at + (line.edited == true ? " · " + settings.say("edited", "bewerkt") : "")).font(.caption2).opacity(0.6).padding(.horizontal, line.kind == nil ? 0 : 6)
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
            if line.mine && line.kind == nil {
                Button { replying = nil; editing = line; typed = line.text } label: { Label(settings.say("Edit", "Bewerken"), systemImage: "pencil") }
            }
            if !line.mine && line.kind == nil && settings.translate && !settings.translateAutomatically && line.translation == nil {
                Button { Task { await chat.translate(line.msgId!, of: code, settings: settings) } } label: { Label(settings.say("Translate", "Vertalen"), systemImage: "globe") }
            }
            ForEach(Self.reactions, id: \.self) { emoji in
                Button(emoji + (line.myReaction == emoji ? " ✓" : "")) { Task { await chat.react(emoji, to: line, of: code) } }
            }
            if line.mine {
                Button(role: .destructive) { Task { problem = await chat.unsend(line, of: code, settings: settings) } } label: {
                    Label(settings.say("Delete for both of you", "Voor jullie allebei verwijderen"), systemImage: "trash")
                }
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
        if line.kind == "poll" {
            PollView(line: line, friendName: friend?.name ?? "", canVote: !(friend?.key.isEmpty ?? true)) { choice in
                Task { await chat.vote(choice, in: line, of: code) }
            }
        } else if let kind = line.kind {
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            VoiceNotePlayer(url: url)
                            // "Aa": what's said in it (worked out the first time), tap again to hide it
                            Button {
                                if showWords.contains(line.id) { showWords.remove(line.id) } else {
                                    showWords.insert(line.id)
                                    if line.transcript == nil, let id = line.msgId { Task { await chat.transcribe(id, of: code, settings: settings) } }
                                }
                            } label: {
                                Text("Aa").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(Color.white.opacity(showWords.contains(line.id) ? 0.3 : 0.12), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.borderless)
                        }
                        if showWords.contains(line.id) {
                            Text(line.transcript == nil || line.transcript == "…" ? settings.say("Working out the words…", "Woorden uitzoeken…") : line.transcript!)
                                .font(.callout).opacity(0.8).frame(maxWidth: 240, alignment: .leading).textSelection(.enabled)
                        }
                    }
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
            if !line.mine, let translation = line.translation, translation != "=" { // in your language
                Text("🌐 " + translation).font(.callout).opacity(0.75).frame(maxWidth: 260, alignment: .leading)
            }
            if let preview = line.preview, preview.url != "-", let link = URL(string: preview.url) { // a link: its page
                Button { openURL(link) } label: { LinkCard(preview: preview) }.buttonStyle(.plain)
            }
        }
    }

    /// A message waiting to be sent at its time, with ✕ to cancel it.
    private func scheduledBubble(_ later: SocialChat.Scheduled) -> some View {
        HStack {
            Spacer(minLength: 50)
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(later.text)
                    Label(later.at.formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(.caption2).opacity(0.7)
                }
                Button { chat.unschedule(later.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.8)) }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .background(Color.davePurple.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        }
    }

    /// "Editing your message" above the box, with ✕.
    private var editBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.caption)
            Text(settings.say("Editing your message", "Je bericht bewerken")).font(.caption)
            Spacer()
            Button { editing = nil; typed = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 6)
    }

    /// ⏰: when to send what you type.
    private var scheduleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.caption)
            DatePicker(settings.say("Send at", "Versturen om"), selection: $sendAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .font(.caption).labelsHidden()
            Spacer()
            Button(settings.say("Schedule", "Inplannen")) {
                let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                chat.schedule(text, to: code, at: sendAt, reply: replying?.msgId)
                typed = ""; replying = nil; scheduling = false
            }
            .font(.caption.bold()).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 18).padding(.top, 6)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Menu {
                Button { pickingPhotos = true } label: { Label(settings.say("Photo or video", "Foto of video"), systemImage: "photo.on.rectangle") }
                Button { pickingFile = true } label: { Label(settings.say("File", "Bestand"), systemImage: "doc") }
                Button { makingPoll = true } label: { Label(settings.say("Poll", "Poll"), systemImage: "chart.bar") }
            } label: {
                Image(systemName: "plus").font(.headline).foregroundStyle(.white).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            if editing == nil {
                Button { scheduling.toggle(); if scheduling { sendAt = Date().addingTimeInterval(3600) } } label: {
                    Image(systemName: "clock").font(.headline).foregroundStyle(.white).frame(width: 40, height: 40)
                        .background(scheduling ? AnyShapeStyle(Color.davePurple.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                }
            }
            TextField(placeholder, text: $typed)
                .submitLabel(.send).onSubmit(send)
                .disabled(recorder.recording)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
                .onChange(of: typed) { text in if !text.isEmpty && editing == nil { Task { await chat.sendTyping(to: code) } } }
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
            .frame(maxWidth: 260)
            .foregroundStyle(.white.opacity(0.65))
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

    private func snippet(_ line: SocialChat.Line) -> String {
        let text = (line.kind == "poll" ? "📊 " : "") + line.text
        return text.count > 90 ? String(text.prefix(90)) + "…" : text
    }

    private var placeholder: String {
        if recorder.recording { return settings.say("🎤 Recording… tap ■ to send", "🎤 Opnemen… tik ■ om te versturen") }
        if sending { return settings.say("Sending…", "Versturen…") }
        if editing != nil { return settings.say("Edit your message…", "Bewerk je bericht…") }
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
        if let editing {
            self.editing = nil
            Task { problem = await chat.edit(editing, to: text, of: code, settings: settings) }
            return
        }
        if scheduling { // the ⏰ bar is open: then the arrow schedules it too
            chat.schedule(text, to: code, at: sendAt, reply: replying?.msgId)
            replying = nil; scheduling = false
            return
        }
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

/// A poll in the chat: each answer with a bar for its votes and who picked it; tap one to vote (again: take it back).
private struct PollView: View {
    let line: SocialChat.Line
    let friendName: String
    let canVote: Bool
    let vote: (Int) -> Void
    private let settings = Settings.shared

    var body: some View {
        let votes = [line.myVote, line.theirVote].compactMap { $0 }.count
        VStack(alignment: .leading, spacing: 7) {
            Text("📊 " + line.text).font(.callout.bold())
            ForEach(Array((line.options ?? []).enumerated()), id: \.offset) { i, answer in
                let count = (line.myVote == i ? 1 : 0) + (line.theirVote == i ? 1 : 0)
                Button { vote(i) } label: {
                    HStack(spacing: 6) {
                        Text(answer).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        if line.myVote == i { voter(settings.say("You", "Jij"), mine: true) }
                        if line.theirVote == i { voter(friendName, mine: false) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(alignment: .leading) {
                        GeometryReader { geo in
                            Color.daveCyan.opacity(0.3).frame(width: geo.size.width * CGFloat(count) / 2)
                        }
                    }
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(line.myVote == i ? Color.daveCyan : Color.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canVote)
                .animation(.easeOut(duration: 0.25), value: count)
            }
            Text(votes == 2 ? settings.say("You both voted", "Jullie hebben allebei gestemd")
                 : line.myVote != nil ? settings.say("Waiting for \(friendName) to vote", "Wacht tot \(friendName) stemt")
                 : line.theirVote != nil ? settings.say("\(friendName) voted — your turn", "\(friendName) heeft gestemd — jij bent")
                 : settings.say("No votes yet", "Nog geen stemmen"))
                .font(.caption).opacity(0.7)
        }
        .frame(width: 250)
    }

    private func voter(_ name: String, mine: Bool) -> some View {
        Text(name).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(mine ? Color.daveViolet.opacity(0.55) : Color.white.opacity(0.16), in: Capsule())
    }
}

/// Making a poll: a question and 2 to 6 answers.
private struct PollMaker: View {
    let done: (String, [String]) -> Void
    @State private var question = ""
    @State private var answers = ["", ""]
    @Environment(\.dismiss) private var dismiss
    private let settings = Settings.shared

    private var ready: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty && answers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(settings.say("Question", "Vraag")) {
                    TextField(settings.say("Ask a question…", "Stel een vraag…"), text: $question)
                }
                Section(settings.say("Answers", "Antwoorden")) {
                    ForEach(answers.indices, id: \.self) { i in
                        TextField(settings.say("Answer", "Antwoord") + " \(i + 1)", text: $answers[i])
                    }
                    .onDelete { rows in if answers.count - rows.count >= 2 { answers.remove(atOffsets: rows) } }
                    if answers.count < 6 {
                        Button { answers.append("") } label: { Label(settings.say("Add an answer", "Antwoord toevoegen"), systemImage: "plus") }
                    }
                }
            }
            .navigationTitle(settings.say("Poll", "Poll"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(settings.say("Cancel", "Annuleren")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.say("Send", "Versturen")) { done(question, answers) }.disabled(!ready)
                }
            }
        }
    }
}

/// A link's page under a message: its picture, title and a bit of its text.
private struct LinkCard: View {
    let preview: SocialChat.Preview

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = URL(string: preview.image), !preview.image.isEmpty {
                AsyncImage(url: image) { picture in picture.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.title).font(.footnote.bold()).lineLimit(2)
                if !preview.text.isEmpty { Text(preview.text).font(.caption).opacity(0.7).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: 260)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Searching a chat: words, what kind (photos, videos, voice, files, links), who sent it, and between which dates.
/// Tap a result to see it in the chat.
private struct ChatSearch: View {
    let lines: [SocialChat.Line]
    let friendName: String
    let found: (UUID) -> Void
    @State private var words = ""
    @State private var kind = ""
    @State private var who = ""
    @State private var useAfter = false
    @State private var after = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var useBefore = false
    @State private var before = Date()
    @Environment(\.dismiss) private var dismiss
    private let settings = Settings.shared

    private var results: [SocialChat.Line] {
        let q = words.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty || !kind.isEmpty || !who.isEmpty || useAfter || useBefore else { return [] }
        return lines.reversed().filter { l in
            if kind == "link" { if SocialChat.firstLink(in: l.text) == nil || l.kind != nil { return false } }
            else if !kind.isEmpty && l.kind != kind { return false }
            if who == "me" && !l.mine || who == "them" && l.mine { return false }
            let day = l.date ?? .distantPast
            if useAfter && day < Calendar.current.startOfDay(for: after) { return false }
            if useBefore, let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: before)), day >= end { return false }
            return q.isEmpty || [l.text, l.name, l.transcript, l.translation].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(settings.say("Kind", "Soort"), selection: $kind) {
                        Text(settings.say("All", "Alles")).tag("")
                        Text("📷 " + settings.say("Photos", "Foto's")).tag("photo")
                        Text("🎬 " + settings.say("Videos", "Video's")).tag("video")
                        Text("🎤 " + settings.say("Voice", "Spraak")).tag("voice")
                        Text("📎 " + settings.say("Files", "Bestanden")).tag("file")
                        Text("🔗 Links").tag("link")
                        Text("📊 Polls").tag("poll")
                    }
                    Picker(settings.say("From", "Van"), selection: $who) {
                        Text(settings.say("Anyone", "Iedereen")).tag("")
                        Text(settings.say("You", "Jij")).tag("me")
                        Text(friendName).tag("them")
                    }
                    Toggle(settings.say("Sent after", "Verstuurd na"), isOn: $useAfter)
                    if useAfter { DatePicker(settings.say("After", "Na"), selection: $after, displayedComponents: .date) }
                    Toggle(settings.say("Sent before", "Verstuurd voor"), isOn: $useBefore)
                    if useBefore { DatePicker(settings.say("Before", "Voor"), selection: $before, displayedComponents: .date) }
                }
                Section {
                    if results.isEmpty && (!words.isEmpty || !kind.isEmpty || !who.isEmpty || useAfter || useBefore) {
                        Text(settings.say("Nothing found", "Niets gevonden")).foregroundStyle(.secondary)
                    }
                    ForEach(results.prefix(80)) { l in
                        Button { found(l.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(l.mine ? settings.say("You", "Jij") : friendName).font(.caption.bold())
                                    Spacer()
                                    Text((l.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "") + " " + l.at).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(l.text).font(.callout).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $words, placement: .navigationBarDrawer(displayMode: .always), prompt: settings.say("Search…", "Zoeken…"))
            .navigationTitle(settings.say("Search", "Zoeken"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(settings.say("Close", "Sluiten")) { dismiss() } } }
        }
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
