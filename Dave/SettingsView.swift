import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var pairStatus = ""
    @State private var spotifyStatus = ""
    @State private var pcVersion: String?

    private func spotifyLogIn() async {
        do {
            try await Spotify.logIn(settings: settings)
            spotifyStatus = ""
        } catch {
            spotifyStatus = "⚠️ " + error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(settings.say("PC address, e.g. 192.168.1.20", "Pc-adres, bv. 192.168.1.20"), text: $settings.pcAddress)
                        .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField(settings.say("Code", "Code"), text: $settings.pcCode).keyboardType(.numberPad)
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            Text(settings.say("Connect to my PC", "Koppel aan mijn pc"))
                            if pairing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(pairing || !settings.hasPC)
                    if !pairStatus.isEmpty { Text(pairStatus).font(.footnote).foregroundStyle(.secondary) }
                    if let away = settings.pcAddresses.first(where: { $0.hasPrefix("100.") }) {
                        Label(settings.say("Away from home too, through Tailscale (\(away))", "Ook als je niet thuis bent, via Tailscale (\(away))"),
                              systemImage: "globe").font(.footnote).foregroundStyle(.green)
                    } else if settings.hasPC {
                        Label(settings.say("Only on the same Wi-Fi as your PC", "Alleen op dezelfde wifi als je pc"), systemImage: "wifi")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(settings.say("Your PC", "Je pc"))
                } footer: {
                    Text(settings.say("On the PC: Dave's settings → iPhone app → turn on and save. The address and code are shown there. Connecting also copies your Groq key, name and language.\n\nAway from home too: install Tailscale (free, tailscale.com) on your PC and this iPhone, log in with the same account on both, and connect once more. Dave then finds your PC by himself, at home and away.",
                                      "Op de pc: instellingen van Dave → iPhone-app → aanzetten en opslaan. Daar staan het adres en de code. Koppelen neemt ook je Groq-sleutel, naam en taal over.\n\nOok als je niet thuis bent: installeer Tailscale (gratis, tailscale.com) op je pc en deze iPhone, log op beide in met hetzelfde account, en koppel nog één keer. Dave vindt je pc dan zelf, thuis en onderweg."))
                }

                if settings.hasPC {
                    Section {
                        if settings.ntfyTopic.isEmpty {
                            Text(settings.say("Off. Turn it on in Dave's settings on the PC: iPhone app → Notifications on my phone.",
                                              "Uit. Zet het aan in de instellingen van Dave op de pc: iPhone-app → Meldingen op mijn telefoon."))
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            LabeledContent(settings.say("Channel", "Kanaal"), value: settings.ntfyTopic).font(.footnote)
                            Button(settings.say("Copy the channel", "Kopieer het kanaal")) { UIPasteboard.general.string = settings.ntfyTopic }
                            Link(settings.say("Get ntfy (free)", "Download ntfy (gratis)"),
                                 destination: URL(string: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=ntfy")!)
                        }
                    } header: {
                        Text(settings.say("Notifications from your PC", "Meldingen van je pc"))
                    } footer: {
                        Text(settings.say("Reminders and heads-ups from your PC (\"Roblox closed\", \"your download is done\") as notifications here, when you're not at your PC. In the ntfy app: + → paste the channel (server ntfy.sh) → Subscribe.",
                                          "Herinneringen en seintjes van je pc (\"Roblox is gesloten\", \"je download is klaar\") als melding hier, als je niet achter je pc zit. In de ntfy-app: + → plak het kanaal (server ntfy.sh) → Subscribe."))
                    }
                }

                Section {
                    SecureField("gsk_…", text: $settings.groqKey).autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text(settings.say("Groq key", "Groq-sleutel"))
                } footer: {
                    Text(settings.say("Free at console.groq.com/keys. Filled in by connecting to your PC.", "Gratis op console.groq.com/keys. Wordt ingevuld door te koppelen."))
                }

                Section {
                    if Spotify.isConnected {
                        Label(settings.say("Logged in: Dave controls your Spotify", "Ingelogd: Dave bedient je Spotify"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button(settings.say("Log out of Spotify", "Uitloggen bij Spotify"), role: .destructive) { Spotify.logOut(settings: settings) }
                    } else {
                        TextField("Client ID", text: $settings.spotifyClientId).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button(settings.say("Log in to Spotify", "Inloggen bij Spotify")) { Task { await spotifyLogIn() } }
                            .disabled(settings.spotifyClientId.isEmpty)
                    }
                    if !spotifyStatus.isEmpty { Text(spotifyStatus).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Spotify (Premium)")
                } footer: {
                    Text(settings.say("Once: on developer.spotify.com/dashboard → your app → Settings → Redirect URIs, add \(Spotify.redirectUri) and save. The Client ID comes from your PC when you connect.",
                                      "Eenmalig: op developer.spotify.com/dashboard → je app → Settings → Redirect URIs, voeg \(Spotify.redirectUri) toe en sla op. De Client ID komt van je pc als je koppelt."))
                }

                Section {
                    ForEach(Theme.all) { theme in
                        Button { settings.theme = theme.id } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(theme.deep)
                                    Circle().fill(theme.legacy
                                                  ? AnyShapeStyle(LinearGradient(colors: [theme.main, theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                  : AnyShapeStyle(AngularGradient(colors: [theme.main, theme.accent, theme.bright, theme.middle, theme.main], center: .center)))
                                        .padding(7)
                                }
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.name).foregroundStyle(.primary)
                                    Text(theme.description).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.theme == theme.id { Image(systemName: "checkmark").foregroundStyle(theme.bright) }
                            }
                        }
                    }
                } header: {
                    Text(settings.say("Theme", "Thema"))
                }

                Section(settings.say("You", "Jij")) {
                    TextField("Dave", text: $settings.name)
                    Picker(settings.say("Language", "Taal"), selection: $settings.language) {
                        Text("Nederlands").tag("nl-NL")
                        Text("English").tag("en-US")
                    }
                    TextField(settings.say("Country", "Land"), text: $settings.country)
                }

                Section {
                    Slider(value: $settings.speechRate, in: 0.4...0.6) {
                        Text(settings.say("Speaking speed", "Spreeksnelheid"))
                    } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                } header: {
                    Text(settings.say("Voice", "Stem"))
                } footer: {
                    Text(settings.say("For a more natural voice: iOS Settings → Accessibility → Spoken Content → Voices → download an Enhanced or Premium voice.",
                                      "Voor een natuurlijkere stem: iOS-instellingen → Toegankelijkheid → Gesproken materiaal → Stemmen → download een Verbeterde of Premium stem."))
                }

                Section(settings.say("About", "Over")) {
                    LabeledContent(settings.say("Dave on this iPhone", "Dave op deze iPhone"),
                                   value: "\(Updater.currentVersion) (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    if settings.hasPC {
                        LabeledContent(settings.say("Dave on your PC", "Dave op je pc"),
                                       value: pcVersion ?? settings.say("not reachable", "niet bereikbaar"))
                    }
                    Link(settings.say("All versions and what's new", "Alle versies en wat er nieuw is"),
                         destination: URL(string: "https://github.com/Jorn-Jansen/Dave-iPhone/releases")!)
                }
            }
            .task { if settings.hasPC { pcVersion = await PCLink.version(settings: settings) } }
            .scrollContentBackground(.hidden)
            .background(Color.daveDeep)
            .navigationTitle(settings.say("Settings", "Instellingen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(settings.say("Done", "Klaar")) { dismiss() } }
            }
        }
    }

    private func pair() async {
        pairing = true
        defer { pairing = false }
        do {
            let config = try await PCLink.pair(settings: settings)
            if let key = config["groqKey"] as? String, !key.isEmpty { settings.groqKey = key }
            if let name = config["name"] as? String, !name.isEmpty { settings.name = name }
            if let language = config["language"] as? String { settings.language = language.hasPrefix("nl") ? "nl-NL" : "en-US" }
            if let country = config["country"] as? String, !country.isEmpty { settings.country = country }
            if let memories = config["memories"] as? [String] { settings.memories = memories }
            if let spotify = config["spotifyClientId"] as? String, !spotify.isEmpty { settings.spotifyClientId = spotify }
            if let addresses = config["addresses"] as? [String], !addresses.isEmpty { settings.pcAddresses = addresses }
            settings.pcLinked = true
            pairStatus = settings.say("✅ Connected to \(settings.displayName) on your PC.", "✅ Gekoppeld aan \(settings.displayName) op je pc.")
        } catch {
            settings.pcLinked = false
            pairStatus = "⚠️ " + error.localizedDescription
        }
    }
}
