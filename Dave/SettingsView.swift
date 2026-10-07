import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var pairStatus = ""
    @State private var spotifyStatus = ""

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
                } header: {
                    Text(settings.say("Your PC", "Je pc"))
                } footer: {
                    Text(settings.say("On the PC: Dave's settings → iPhone app → turn on and save. The address and code are shown there. Connecting also copies your Groq key, name and language.",
                                      "Op de pc: instellingen van Dave → iPhone-app → aanzetten en opslaan. Daar staan het adres en de code. Koppelen neemt ook je Groq-sleutel, naam en taal over."))
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

                if !settings.memories.isEmpty {
                    Section(settings.say("What I remember (from the PC)", "Wat ik onthoud (van de pc)")) {
                        ForEach(settings.memories, id: \.self) { Text($0).font(.footnote) }
                    }
                }
            }
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
            settings.pcLinked = true
            pairStatus = settings.say("✅ Connected to \(settings.displayName) on your PC.", "✅ Gekoppeld aan \(settings.displayName) op je pc.")
        } catch {
            settings.pcLinked = false
            pairStatus = "⚠️ " + error.localizedDescription
        }
    }
}
