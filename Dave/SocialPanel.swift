import SwiftUI
import UIKit

/// Chats with friends who use Dave too, like the Social tab on the PC (the same friend code and chats: Dave on the PC sends
/// and receives them, the phone shows them and sends through it). Refreshes every few seconds while it's open.
struct SocialPanel: View {
    @ObservedObject var data: PCData
    @State private var newCode = ""
    @State private var chatting: String? // the friend whose chat is open
    @State private var noteShown = false
    private let settings = Settings.shared

    var body: some View {
        NavigationStack {
            Panel(settings.say("Social", "Sociaal"), data: data) {
                GlassList(data: data) {
                    Section {
                        row {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(settings.say("Your friend code", "Jouw vriendcode")).font(.caption).foregroundStyle(.secondary)
                                    Text(data.friendCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                }
                                Spacer()
                                Button { UIPasteboard.general.string = data.friendCode; data.note = settings.say("Copied!", "Gekopieerd!") } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                ShareLink(item: settings.say("Add me in Dave (Social tab): \(data.friendCode)", "Voeg me toe in Dave (tabblad Sociaal): \(data.friendCode)")) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        row {
                            HStack {
                                TextField(settings.say("Paste a friend's code…", "Plak de code van een vriend…"), text: $newCode)
                                    .textInputAutocapitalization(.characters).autocorrectionDisabled().onSubmit(add)
                                Button(action: add) { Image(systemName: "person.badge.plus").font(.title3) }
                                    .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    } footer: {
                        Text(settings.say("The same friends and chats as on your PC. You can also say \"tell Alex I'm online\" or \"any messages?\".",
                                          "Dezelfde vrienden en chats als op je pc. Je kunt ook zeggen \"zeg tegen Alex dat ik online ben\" of \"heb ik berichten?\"."))
                    }

                    let asking = data.friends.filter { $0.status != "friend" }
                    if !asking.isEmpty {
                        Section(settings.say("Friend requests", "Vriendverzoeken")) {
                            ForEach(asking) { f in
                                row {
                                    HStack(spacing: 12) {
                                        Avatar(name: f.name)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(f.name).font(.headline)
                                            Text(f.status == "incoming" ? settings.say("wants to be friends", "wil vrienden worden")
                                                                        : settings.say("waiting for them to accept", "wacht tot die accepteert"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if f.status == "incoming" {
                                            Button(settings.say("Accept", "Accepteren")) { Task { await data.change(["type": "socialAccept", "code": f.code]) } }
                                                .buttonStyle(.borderedProminent).tint(.davePurple)
                                        }
                                        Button { Task { await data.change(["type": "socialRemove", "code": f.code]) } } label: { Image(systemName: "xmark") }
                                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section(settings.say("Friends", "Vrienden")) {
                        let friends = data.friends.filter { $0.status == "friend" }
                        if friends.isEmpty {
                            row {
                                Text(settings.say("No friends yet. Send your friend code to a friend who uses Dave, or paste theirs above.",
                                                  "Nog geen vrienden. Stuur je vriendcode naar een vriend die Dave gebruikt, of plak die van hen hierboven."))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(friends) { f in
                            row {
                                NavigationLink(value: f.code) {
                                    HStack(spacing: 12) {
                                        Avatar(name: f.name)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(f.name).font(.headline)
                                            Text(f.last.isEmpty ? "…" : f.last).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if f.unread > 0 {
                                            Text("\(f.unread)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                                                .background(LinearGradient(colors: [.davePurple, .davePink], startPoint: .leading, endPoint: .trailing), in: Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { let code = friends[index].code; Task { await data.change(["type": "socialRemove", "code": code]) } }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { code in ChatView(data: data, code: code) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            // New messages and requests show up while you're here
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await data.refresh()
            }
        }
        .onChange(of: data.note) { note in noteShown = note != nil }
        .alert(data.note ?? "", isPresented: $noteShown) { Button("OK") { data.note = nil } }
    }

    private func add() {
        let code = newCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        newCode = ""
        Task { await data.change(["type": "socialAdd", "text": code]) }
    }

    private func row<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().listRowBackground(Color.white.opacity(0.07))
    }
}

/// A friend's first letter in a circle, in the theme's colours.
private struct Avatar: View {
    let name: String
    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.headline).foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(LinearGradient(colors: [.davePurple, .daveCyan], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
    }
}

/// One chat: the messages (yours on the right), and a box to write a new one.
private struct ChatView: View {
    @ObservedObject var data: PCData
    let code: String
    @State private var typed = ""
    private let settings = Settings.shared

    private var friend: PCData.Friend? { data.friends.first { $0.code == code } }

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if friend?.secure != true { // only a warning; encrypted is simply how it is
                                Text(settings.say("⚠️ Not encrypted yet: they need the latest Dave", "⚠️ Nog niet versleuteld: ze hebben de nieuwste Dave nodig"))
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            if friend?.lines.isEmpty ?? true {
                                Text(settings.say("No messages yet. Say hi!", "Nog geen berichten. Zeg hoi!")).foregroundStyle(.secondary).padding(.top, 40)
                            }
                            ForEach(friend?.lines ?? []) { line in
                                HStack {
                                    if line.mine { Spacer(minLength: 50) }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(line.text)
                                        Text(line.at).font(.caption2).opacity(0.6)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(line.mine
                                                ? AnyShapeStyle(LinearGradient(colors: [.davePurple.opacity(0.85), .daveViolet.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                : AnyShapeStyle(.ultraThinMaterial),
                                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .textSelection(.enabled)
                                    if !line.mine { Spacer(minLength: 50) }
                                }
                                .id(line.id)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear { scrollDown(scroll) }
                    .onChange(of: friend?.lines.count ?? 0) { _ in withAnimation { scrollDown(scroll) } }
                }
                HStack(spacing: 10) {
                    TextField(settings.say("Message…", "Bericht…"), text: $typed)
                        .submitLabel(.send).onSubmit(send)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                    if !typed.isEmpty {
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.headline.bold()).foregroundStyle(.white).frame(width: 44, height: 44)
                                .background(LinearGradient(colors: [.davePurple, .davePink], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .navigationTitle(friend?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            if (friend?.unread ?? 0) > 0 { await data.change(["type": "socialRead", "code": code]) } // you're reading it
        }
    }

    private func scrollDown(_ scroll: ScrollViewProxy) {
        if let last = friend?.lines.last { scroll.scrollTo(last.id, anchor: .bottom) }
    }

    private func send() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        Task { await data.change(["type": "socialSend", "code": code, "text": text]) }
    }
}
