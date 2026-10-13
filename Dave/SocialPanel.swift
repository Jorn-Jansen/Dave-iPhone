import AVKit
import PhotosUI
import SwiftUI
import UIKit

/// Chats with friends who use Dave too, like the Social tab on the PC: the same friend code, friends and chats. Chatting
/// works straight from the phone (SocialChat), also when the PC is off; adding and accepting friends goes through the PC.
/// Checks for new messages every few seconds while it's open.
struct SocialPanel: View {
    @ObservedObject var data: PCData
    @ObservedObject private var chat = SocialChat.shared
    @State private var newCode = ""
    @State private var noteShown = false
    private let settings = Settings.shared

    var body: some View {
        NavigationStack {
            Panel(settings.say("Social", "Sociaal"), data: data, needsPC: false) {
                if !chat.ready {
                    VStack {
                        Spacer()
                        Text(settings.hasPC ? settings.say("Getting your chats from your PC…", "Ik haal je chats van je pc…")
                                            : settings.say("Connect me to your PC once (⚙) to chat with your friends. After that it works without your PC too.",
                                                           "Koppel me één keer aan je pc (⚙) om met je vrienden te chatten. Daarna werkt het ook zonder je pc."))
                            .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7)).padding(30)
                        Spacer()
                    }
                } else {
                    list
                }
            }
            .navigationDestination(for: String.self) { code in ChatView(code: code) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await chat.listen() } // new messages (and "typing…") as they come, while this tab is open
        .task {
            // Your friends (and requests) from the PC now and then, when it can be reached
            while !Task.isCancelled {
                await data.refresh()
                await chat.sync(settings: settings, pcFriends: data.friends)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: data.note) { note in noteShown = note != nil }
        .alert(data.note ?? "", isPresented: $noteShown) { Button("OK") { data.note = nil } }
    }

    private var list: some View {
        GlassList(data: data) {
            Section {
                row {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.say("Your friend code", "Jouw vriendcode")).font(.caption).foregroundStyle(.secondary)
                            Text(chat.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        Spacer()
                        Button { UIPasteboard.general.string = chat.code; data.note = settings.say("Copied!", "Gekopieerd!") } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        ShareLink(item: settings.say("Add me in Dave (Social tab): \(chat.code)", "Voeg me toe in Dave (tabblad Sociaal): \(chat.code)")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if settings.hasPC {
                    row {
                        HStack {
                            TextField(settings.say("Paste a friend's code…", "Plak de code van een vriend…"), text: $newCode)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().onSubmit(add)
                            Button(action: add) { Image(systemName: "person.badge.plus").font(.title3) }
                                .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } footer: {
                Text(settings.say("The same friends and chats as on your PC, end-to-end encrypted. Chatting also works when your PC is off; adding friends needs it.",
                                  "Dezelfde vrienden en chats als op je pc, end-to-end versleuteld. Chatten werkt ook als je pc uit staat; vrienden toevoegen kan alleen via je pc."))
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
                                    Button(settings.say("Accept", "Accepteren")) { change(["type": "socialAccept", "code": f.code]) }
                                        .buttonStyle(.borderedProminent).tint(.davePurple)
                                }
                                Button { change(["type": "socialRemove", "code": f.code]) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section(settings.say("Friends", "Vrienden")) {
                let friends = chat.friends.filter { $0.status == "friend" }
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
                                    let last = chat.chats[f.code]?.last
                                    Text(last.map { ($0.mine ? settings.say("You: ", "Jij: ") : "") + $0.text } ?? "…")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    guard settings.hasPC else { return }
                    for index in offsets { change(["type": "socialRemove", "code": friends[index].code]) }
                }
            }
        }
    }

    /// Adding, accepting or removing a friend: done by Dave on the PC, then the friends list here is brought up to date.
    private func change(_ change: [String: Any]) {
        Task {
            await data.change(change)
            await chat.sync(settings: settings, pcFriends: data.friends)
        }
    }

    private func add() {
        let code = newCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        newCode = ""
        change(["type": "socialAdd", "text": code])
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

