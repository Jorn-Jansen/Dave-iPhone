import MediaPlayer
import PDFKit
import Photos
import UIKit

/// What Dave can do on the iPhone itself: open apps (and search in them), run your Shortcuts, look at what you
/// copied, your photos, and a file you pick. iOS only allows apps this much: no free search through your files,
/// and only apps that can be opened by a link.
enum PhoneTools {
    static var definitions: [[String: Any]] {
        [
            tool("music", "Music, like pressing the buttons: play, pause, next or previous song, what's playing, play something "
                 + "('play lofi', 'play Drake', 'play my Chill playlist'), Spotify's volume. Spotify plays on whatever device it's on "
                 + "(this iPhone, the PC, a speaker). Use this, not open_app, for playing and pausing.",
                 ["action": ["type": "string", "enum": ["play", "pause", "next", "previous", "now_playing", "play_something", "volume"]],
                  "query": str("play_something: what to play"),
                  "kind": ["type": "string", "enum": ["any", "track", "artist", "playlist", "album"]],
                  "level": ["type": "integer", "description": "volume: 0-100"]],
                 required: ["action"]),
            tool("phone_reminder", "A reminder or timer on this iPhone, as a notification (also with the app closed and the PC off): "
                 + "'remind me at 8 to call mom', 'timer for 10 minutes', 'every day at 7 take my pills'. Or cancel one.",
                 ["action": ["type": "string", "enum": ["set", "cancel"]],
                  "message": str("set: what to remind of, in the user's language"),
                  "minutes": ["type": "number", "description": "set: from now (fractions allowed)"],
                  "time": str("set: clock time HH:mm (24h), instead of minutes"),
                  "repeat": ["type": "string", "enum": ["none", "daily"]],
                  "which": str("cancel: words from the reminder; empty for all")],
                 required: ["action"]),
            tool("send_to_pc", "Send something from this iPhone to the user's PC: what they copied (a link opens in the PC's browser, "
                 + "text goes on the PC's clipboard, a picture is saved), their last photo, or a file they pick (saved in Downloads on the PC).",
                 ["what": ["type": "string", "enum": ["clipboard", "last_photo", "file"]]],
                 required: ["what"]),
            tool("open_app","Open an app on the iPhone, optionally searching in it: 'open Spotify', 'search lofi in Spotify', "
                 + "'directions to Utrecht', 'open youtube.com'. Also websites.",
                 ["app": str("The app's name, e.g. 'Spotify', 'WhatsApp', 'Maps'"),
                  "search": str("What to search or navigate to in it, if said"),
                  "url": str("A website address, if they want a site")], required: ["app"]),
            tool("run_shortcut", "Run one of the user's Siri Shortcuts by name (they can do anything: open apps, change settings, smart home).",
                 ["name": str("The shortcut's name, exactly as the user said it")], required: ["name"]),
            tool("use_clipboard", "Work with what the user copied on the iPhone (text or a picture): read it out, summarise, translate, explain, what's in the picture.",
                 ["task": str("What to do with it, in the user's words")], required: ["task"]),
            tool("photos", "The user's photos: look at one ('what's in my last screenshot', 'read the text on my last photo'), "
                 + "find them by what's in them ('find my photos of a dog', 'pictures of the beach'), "
                 + "or by date, kind or favourites ('how many photos did I take yesterday', 'show my favourites from last week').",
                 ["action": ["type": "string", "enum": ["look", "find"], "description": "look = answer about the picture(s); find = count and show them"],
                  "content": str("Only to find photos by what's in them: simple English words (singular), comma-separated, with close "
                                 + "alternatives, e.g. 'dog, puppy' or 'beach, sea' or 'food' or 'car'"),
                  "question": str("For look: the user's question about the picture(s)"),
                  "kind": ["type": "string", "enum": ["any", "photo", "screenshot", "selfie", "video", "favorite"]],
                  "from_date": str("First day, yyyy-MM-dd, if a period was said"),
                  "to_date": str("Last day, yyyy-MM-dd"),
                  "count": ["type": "integer", "description": "How many (newest first): 1 for 'my last photo'; at most 4 for look"]],
                 required: ["action", "kind"]),
            tool("read_file", "Let the user pick a file on their iPhone (Files, iCloud Drive) and read it to answer about it: summarise, explain, review. "
                 + "Text, PDF and pictures.",
                 ["question": str("What the user wants to know about the file")], required: ["question"]),
        ]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    private static func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    // MARK: Apps

    /// Link schemes of well-known apps (the iPhone opens the app for these), and how to search in them.
    private static let apps: [String: (open: String, search: ((String) -> String)?)] = [
        "spotify": ("spotify://", { "spotify:search:\($0)" }),
        "youtube": ("youtube://", { "youtube://results?search_query=\($0)" }),
        "maps": ("maps://", { "maps://?daddr=\($0)" }),
        "apple maps": ("maps://", { "maps://?daddr=\($0)" }),
        "google maps": ("comgooglemaps://", { "comgooglemaps://?daddr=\($0)" }),
        "whatsapp": ("whatsapp://", { "whatsapp://send?text=\($0)" }),
        "instagram": ("instagram://", nil),
        "tiktok": ("snssdk1233://", nil),
        "snapchat": ("snapchat://", nil),
        "discord": ("discord://", nil),
        "netflix": ("nflx://", nil),
        "roblox": ("roblox://", nil),
        "twitter": ("twitter://", nil),
        "x": ("twitter://", nil),
        "reddit": ("reddit://", nil),
        "gmail": ("googlegmail://", nil),
        "chrome": ("googlechrome://", nil),
        "telegram": ("tg://", nil),
        "messenger": ("fb-messenger://", nil),
        "facebook": ("fb://", nil),
        "twitch": ("twitch://", nil),
        "pinterest": ("pinterest://", nil),
        "duolingo": ("duolingo://", nil),
        "mail": ("message://", nil),
        "messages": ("sms:", nil),
        "phone": ("tel:", nil),
        "facetime": ("facetime:", nil),
        "photos": ("photos-redirect://", nil),
        "music": ("music://", { "music://search?term=\($0)" }),
        "apple music": ("music://", { "music://search?term=\($0)" }),
        "podcasts": ("podcasts://", nil),
        "notes": ("mobilenotes://", nil),
        "calendar": ("calshow://", nil),
        "shortcuts": ("shortcuts://", nil),
        "app store": ("itms-apps://", { "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=\($0)" }),
        "settings": (UIApplication.openSettingsURLString, nil),
        "safari": ("https://www.google.com", { "https://www.google.com/search?q=\($0)" }),
        "google": ("https://www.google.com", { "https://www.google.com/search?q=\($0)" }),
    ]

    /// Open the app (or website). Returns what to say: empty when it opened (the app speaks for itself).
    @MainActor
    static func openApp(_ args: [String: Any], settings: Settings) async -> String {
        let name = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let search = (args["search"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if var site = args["url"] as? String, !site.isEmpty {
            if !site.contains("://") { site = "https://" + site }
            if let url = URL(string: site), await UIApplication.shared.open(url) { return "" }
        }
        let key = name.lowercased()
        let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
        var links: [String] = []
        if let known = apps[key] {
            if !search.isEmpty, let make = known.search { links.append(make(encoded)) }
            links.append(known.open)
        } else {
            // Many apps answer to their own name: "duolingo://", "strava://"
            links.append(key.filter { $0.isLetter || $0.isNumber } + "://")
        }
        for link in links {
            if let url = URL(string: link), await UIApplication.shared.open(url) { return "" }
        }
        return settings.say("I can't open \(name) from here: it isn't installed, or it can't be opened by another app. A Siri Shortcut that opens it would work: tell me its name.",
                            "Ik kan \(name) niet vanaf hier openen: het staat er niet op, of het laat zich niet door een andere app openen. Een Siri-opdracht die het opent werkt wel: zeg me de naam.")
    }

    @MainActor
    static func runShortcut(_ args: [String: Any], settings: Settings) async -> String {
        let name = args["name"] as? String ?? ""
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)"), await UIApplication.shared.open(url) { return "" }
        return settings.say("The Shortcuts app didn't open.", "De Opdrachten-app ging niet open.")
    }

    // MARK: Music

    /// Spotify through the user's account when logged in; otherwise Apple Music, the only app iOS lets others control.
    @MainActor
    static func music(_ args: [String: Any], settings: Settings) async throws -> String {
        let action = args["action"] as? String ?? "play"
        if Spotify.isConnected {
            switch action {
            case "now_playing":
                return try await Spotify.nowPlaying(settings: settings).map { settings.say("Now playing: ", "Nu speelt: ") + $0 }
                    ?? settings.say("Nothing is playing on Spotify.", "Er speelt niets op Spotify.")
            case "play_something":
                return try await Spotify.play(args["query"] as? String ?? "", kind: args["kind"] as? String ?? "any", settings: settings)
            case "volume":
                return try await Spotify.setVolume(args["level"] as? Int ?? 50, settings: settings)
            default:
                return try await Spotify.control(action, settings: settings)
            }
        }
        let player = MPMusicPlayerController.systemMusicPlayer
        switch action {
        case "pause": player.pause(); return "⏸ " + settings.say("Paused", "Gepauzeerd")
        case "next": player.skipToNextItem(); return "⏭ " + settings.say("Next song", "Volgende nummer")
        case "previous": player.skipToPreviousItem(); return "⏮ " + settings.say("Previous song", "Vorige nummer")
        case "play": player.play(); return "▶ " + settings.say("Playing", "Speelt af")
        case "now_playing":
            if let item = player.nowPlayingItem { return settings.say("Now playing: ", "Nu speelt: ") + "\(item.title ?? "") – \(item.artist ?? "")" }
            return settings.say("Nothing is playing in Apple Music.", "Er speelt niets in Apple Music.")
        default:
            return settings.say("For that, log me in to Spotify in the settings. Without it I can only play, pause and skip Apple Music.",
                                "Daarvoor moet je me inloggen bij Spotify in de instellingen. Zonder kan ik alleen Apple Music afspelen, pauzeren en overslaan.")
        }
    }

    // MARK: Sending to the PC

    /// "Send this to my PC": what was copied, the last photo, or a file (picked here). Returns what the PC said.
    @MainActor
    static func sendToPC(_ args: [String: Any], settings: Settings, pickFile: () async -> URL?) async -> String {
        guard settings.hasPC else { return settings.say("Connect me to your PC first (⚙).", "Koppel me eerst aan je pc (⚙).") }
        switch args["what"] as? String {
        case "last_photo":
            guard let (data, name) = await lastPhoto() else {
                return settings.say("I can't get your last photo (is Photos access on for Dave?).", "Ik kan je laatste foto niet pakken (mag Dave bij je foto's?).")
            }
            return await deliver(["kind": "file", "name": name, "data": data.base64EncodedString()], settings: settings)
        case "file":
            guard let url = await pickFile() else { return settings.say("Okay, no file then.", "Oké, dan geen bestand.") }
            return await send(file: url, settings: settings)
        default:
            let board = UIPasteboard.general
            if board.hasImages, let image = board.image, let jpeg = image.jpegData(compressionQuality: 0.9) {
                return await deliver(["kind": "file", "name": "Copied picture.jpg", "data": jpeg.base64EncodedString()], settings: settings)
            }
            if board.hasURLs, let url = board.url, url.scheme?.hasPrefix("http") == true {
                return await deliver(["kind": "url", "text": url.absoluteString], settings: settings)
            }
            if let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let isLink = !text.contains(" ") && (text.hasPrefix("http://") || text.hasPrefix("https://"))
                return await deliver(["kind": isLink ? "url" : "text", "text": text], settings: settings)
            }
            return settings.say("Nothing is copied right now.", "Er is nu niets gekopieerd.")
        }
    }

    /// A file (picked, or opened in Dave from another app) to the PC's Downloads.
    @MainActor
    static func send(file url: URL, settings: Settings) async -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return settings.say("I can't read that file.", "Ik kan dat bestand niet lezen.") }
        return await deliver(["kind": "file", "name": url.lastPathComponent, "data": data.base64EncodedString()], settings: settings)
    }

    @MainActor
    private static func deliver(_ item: [String: Any], settings: Settings) async -> String {
        if let data = item["data"] as? String, data.count > 80_000_000 {
            return settings.say("That's too big to send (the limit is about 60 MB).", "Dat is te groot om te sturen (de grens is zo'n 60 MB).")
        }
        do { return "📤 " + (try await PCLink.send(item, settings: settings)) }
        catch { return error.localizedDescription }
    }

    /// The newest photo, as a JPEG the PC can open (iPhones save HEIC), with its own name.
    private static func lastPhoto() async -> (Data, String)? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { return nil }
        let original = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo.jpg"
        let name = (original as NSString).deletingPathExtension + ".jpg"
        let data: Data? = await withCheckedContinuation { done in
            let request = PHImageRequestOptions()
            request.isNetworkAccessAllowed = true
            request.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: request) { data, _, _, _ in done.resume(returning: data) }
        }
        guard let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (jpeg, name)
    }

    // MARK: Clipboard

    /// What's copied: text, or a picture. iOS asks "Allow Paste" unless Dave may always paste (iOS Settings → Dave).
    @MainActor
    static func clipboard() -> (text: String?, image: UIImage?) {
        let board = UIPasteboard.general
        if board.hasImages, let image = board.image { return (nil, image) }
        if board.hasStrings, let text = board.string, !text.isEmpty { return (text, nil) }
        if board.hasURLs, let url = board.url { return (url.absoluteString, nil) }
        return (nil, nil)
    }

    // MARK: Photos

    struct FoundPhotos {
        let total: Int
        let images: [UIImage]
        let dates: [Date]
    }

    /// Photos matching the kind and dates, newest first: how many there are, and up to [count] of them as pictures.
    static func findPhotos(_ args: [String: Any], count: Int, size: CGFloat) async -> FoundPhotos? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var conditions: [NSPredicate] = []
        let kind = args["kind"] as? String ?? "any"
        switch kind {
        case "video": conditions.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case "screenshot":
            conditions.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
        case "favorite": conditions.append(NSPredicate(format: "favorite == YES"))
        case "photo", "selfie": conditions.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        default: break
        }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        if let from = (args["from_date"] as? String).flatMap(day.date(from:)) {
            conditions.append(NSPredicate(format: "creationDate >= %@", from as NSDate))
            let to = (args["to_date"] as? String).flatMap(day.date(from:)) ?? from
            conditions.append(NSPredicate(format: "creationDate < %@", Calendar.current.date(byAdding: .day, value: 1, to: to)! as NSDate))
        }
        if !conditions.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: conditions) }

        let result: PHFetchResult<PHAsset>
        if kind == "selfie",
           let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil).firstObject {
            result = PHAsset.fetchAssets(in: album, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }

        var images: [UIImage] = []
        var dates: [Date] = []
        for index in 0..<min(count, result.count) {
            let asset = result.object(at: index)
            if let image = await load(asset, size: size) {
                images.append(image)
                dates.append(asset.creationDate ?? Date())
            }
        }
        return FoundPhotos(total: result.count, images: images, dates: dates)
    }

    /// Pictures of [assets] (in order), e.g. to show what a search found.
    static func images(of assets: [PHAsset], size: CGFloat) async -> [UIImage] {
        var images: [UIImage] = []
        for asset in assets { if let image = await load(asset, size: size) { images.append(image) } }
        return images
    }

    private static func load(_ asset: PHAsset, size: CGFloat) async -> UIImage? {
        await withCheckedContinuation { done in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // one answer, not a blurry one first
            options.isNetworkAccessAllowed = true // photos that are only in iCloud
            options.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size), contentMode: .aspectFit,
                                                  options: options) { image, _ in done.resume(returning: image) }
        }
    }

    // MARK: Files

    /// Text from a picked file (cut to what fits one AI request), or a picture. Nil text and picture: can't be read.
    static func read(_ url: URL) -> (text: String?, image: UIImage?, cut: Bool) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let maxText = 7000
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            let text = pdf.string ?? ""
            return (String(text.prefix(maxText)), nil, text.count > maxText)
        }
        guard let data = try? Data(contentsOf: url) else { return (nil, nil, false) }
        if let image = UIImage(data: data) { return (nil, image, false) }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), !text.contains("\u{0}") {
            return (String(text.prefix(maxText)), nil, text.count > maxText)
        }
        return (nil, nil, false)
    }
}
