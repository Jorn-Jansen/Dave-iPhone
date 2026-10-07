import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Controlling Spotify through your Spotify account (Premium): play, pause, skip, what's playing, play something, on
/// whichever device Spotify plays on (this iPhone, your PC, a speaker). iOS doesn't let one app press play in another,
/// but Spotify's own service can. The phone logs in by itself, with the same Spotify developer app as the PC Dave.
@MainActor
enum Spotify {
    /// Has to be added as a Redirect URI in the Spotify developer app (developer.spotify.com/dashboard).
    static let redirectUri = "dave-iphone://spotify-callback"
    private static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private user-library-read"
    private static let accounts = "https://accounts.spotify.com"
    private static let api = "https://api.spotify.com/v1"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isConnected: Bool { !Settings.shared.spotifyRefreshToken.isEmpty }

    // MARK: Logging in

    private static var session: ASWebAuthenticationSession?
    private static let presenter = Presenter()

    /// Spotify's login page; afterwards Spotify sends the phone a code, which becomes a lasting login.
    static func logIn(settings: Settings) async throws {
        let clientId = settings.spotifyClientId.trimmingCharacters(in: .whitespaces)
        guard !clientId.isEmpty else {
            throw Failure(message: settings.say("I need the Client ID of your Spotify app first (connecting to your PC fills it in).",
                                                "Ik heb eerst de Client ID van je Spotify-app nodig (koppelen met je pc vult hem in)."))
        }
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: accounts + "/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "scope", value: scopes), .init(name: "redirect_uri", value: redirectUri),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { done in
            let login = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "dave-iphone") { url, error in
                if let url { done.resume(returning: url) }
                else { done.resume(throwing: Failure(message: settings.say("Logging in to Spotify was cancelled.", "Inloggen bij Spotify is afgebroken."))) }
                _ = error
            }
            login.presentationContextProvider = presenter
            login.prefersEphemeralWebBrowserSession = false
            session = login
            login.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            let reason = items.first(where: { $0.name == "error" })?.value ?? "?"
            throw Failure(message: settings.say("Spotify didn't allow it (\(reason)).", "Spotify stond het niet toe (\(reason))."))
        }
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectUri, "client_id": clientId, "code_verifier": verifier],
                        settings: settings)
    }

    static func logOut(settings: Settings) {
        settings.spotifyRefreshToken = ""
        settings.spotifyAccessToken = ""
    }

    private static func token(_ form: [String: String], settings: Settings) async throws {
        var request = URLRequest(url: URL(string: accounts + "/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            if form["grant_type"] == "refresh_token" { logOut(settings: settings) }
            let reason = json["error_description"] as? String ?? json["error"] as? String ?? "?"
            throw Failure(message: settings.say("Spotify refused the login (\(reason)). Log in again in the settings.",
                                                "Spotify weigerde de login (\(reason)). Log opnieuw in bij de instellingen."))
        }
        settings.spotifyAccessToken = access
        settings.spotifyTokenExpires = Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60).timeIntervalSince1970
        if let refresh = json["refresh_token"] as? String { settings.spotifyRefreshToken = refresh }
    }

    private static func accessToken(settings: Settings) async throws -> String {
        guard isConnected else {
            throw Failure(message: settings.say("I'm not logged in to Spotify yet: do that in the settings.", "Ik ben nog niet ingelogd bij Spotify: doe dat in de instellingen."))
        }
        if Date().timeIntervalSince1970 >= settings.spotifyTokenExpires || settings.spotifyAccessToken.isEmpty {
            try await token(["grant_type": "refresh_token", "refresh_token": settings.spotifyRefreshToken, "client_id": settings.spotifyClientId], settings: settings)
        }
        return settings.spotifyAccessToken
    }

    // MARK: Calling Spotify

    @discardableResult
    private static func call(_ method: String, _ path: String, body: [String: Any]? = nil, settings: Settings) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: api + path)!, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken(settings: settings))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if method != "GET" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 403, ((json["error"] as? [String: Any])?["reason"] as? String) == "PREMIUM_REQUIRED" {
            throw Failure(message: settings.say("Spotify only lets apps control playback with Premium.", "Spotify laat apps alleen afspelen bedienen met Premium."))
        }
        return (status, json)
    }

    /// Play, pause, next, previous. When Spotify isn't playing anywhere, it starts on this iPhone (opening Spotify if needed).
    static func control(_ action: String, settings: Settings) async throws -> String {
        let (method, path) = switch action {
        case "pause": ("PUT", "/me/player/pause")
        case "next": ("POST", "/me/player/next")
        case "previous": ("POST", "/me/player/previous")
        default: ("PUT", "/me/player/play")
        }
        var (status, _) = try await call(method, path, settings: settings)
        if status == 404 { // no active device: wake one up
            guard try await activateDevice(play: action == "play", settings: settings) else { return noDevice(settings) }
            if action != "play" { (status, _) = try await call(method, path, settings: settings) } else { status = 204 }
        }
        guard (200..<300).contains(status) else { return settings.say("Spotify didn't do that (\(status)).", "Spotify deed dat niet (\(status)).") }
        return switch action {
        case "pause": "⏸ " + settings.say("Paused", "Gepauzeerd")
        case "next": "⏭ " + settings.say("Next song", "Volgende nummer")
        case "previous": "⏮ " + settings.say("Previous song", "Vorige nummer")
        default: "▶ " + settings.say("Playing", "Speelt af")
        }
    }

    /// "Play lofi", "play Drake", "play my Chill playlist": the best match, on the active device.
    static func play(_ query: String, kind: String, settings: Settings) async throws -> String {
        let types = kind == "any" || kind.isEmpty ? "track,artist,playlist,album" : kind
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (_, found) = try await call("GET", "/search?q=\(q)&type=\(types)&limit=1", settings: settings)
        func first(_ type: String) -> [String: Any]? { ((found[type + "s"] as? [String: Any])?["items"] as? [Any])?.compactMap { $0 as? [String: Any] }.first }
        var body: [String: Any]
        var title: String
        if (kind == "track" || kind == "any" || kind.isEmpty), let track = first("track"), kind != "any" || first("artist") == nil || isCloser(track, than: first("artist")!, to: query) {
            body = ["uris": [track["uri"] as? String ?? ""]]
            title = "\(track["name"] as? String ?? "") – \(((track["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? "")"
        } else if let item = first(kind == "any" || kind.isEmpty ? "artist" : kind) ?? first("playlist") ?? first("album") {
            body = ["context_uri": item["uri"] as? String ?? ""]
            title = item["name"] as? String ?? query
        } else {
            return settings.say("I couldn't find \(query) on Spotify.", "Ik kon \(query) niet vinden op Spotify.")
        }
        var (status, _) = try await call("PUT", "/me/player/play", body: body, settings: settings)
        if status == 404 {
            guard try await activateDevice(play: false, settings: settings) else { return noDevice(settings) }
            (status, _) = try await call("PUT", "/me/player/play", body: body, settings: settings)
        }
        return (200..<300).contains(status) ? "▶ " + title : settings.say("Spotify didn't play it (\(status)).", "Spotify speelde het niet (\(status)).")
    }

    /// Prefer the track when its name is the query; otherwise the artist ("play Drake").
    private static func isCloser(_ track: [String: Any], than artist: [String: Any], to query: String) -> Bool {
        let q = query.lowercased()
        let artistName = (artist["name"] as? String ?? "").lowercased()
        return !(q == artistName || q.contains(artistName) && !artistName.isEmpty)
    }

    /// What Spotify is playing right now (on any device), or nil.
    static func nowPlaying(settings: Settings) async throws -> String? {
        let (status, json) = try await call("GET", "/me/player/currently-playing", settings: settings)
        guard status == 200, let item = json["item"] as? [String: Any] else { return nil }
        let artist = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        return "\(item["name"] as? String ?? "") – \(artist)" + ((json["is_playing"] as? Bool) == false ? settings.say(" (paused)", " (gepauzeerd)") : "")
    }

    static func setVolume(_ level: Int, settings: Settings) async throws -> String {
        let (status, _) = try await call("PUT", "/me/player/volume?volume_percent=\(max(0, min(100, level)))", settings: settings)
        return (200..<300).contains(status) ? "🔊 \(level)%" : settings.say("Spotify can't change the volume on this device.", "Spotify kan het volume op dit apparaat niet veranderen.")
    }

    /// Nothing playing anywhere: play on a device Spotify knows (this iPhone first); none known → open Spotify here.
    private static func activateDevice(play: Bool, settings: Settings) async throws -> Bool {
        for attempt in 0..<2 {
            let (_, json) = try await call("GET", "/me/player/devices", settings: settings)
            let devices = (json["devices"] as? [[String: Any]]) ?? []
            if let device = devices.first(where: { ($0["type"] as? String) == "Smartphone" }) ?? devices.first, let id = device["id"] as? String {
                try await call("PUT", "/me/player", body: ["device_ids": [id], "play": play], settings: settings)
                try? await Task.sleep(nanoseconds: 600_000_000)
                return true
            }
            if attempt == 0, let url = URL(string: "spotify://") {
                _ = await UIApplication.shared.open(url) // opening Spotify makes this iPhone a device
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        return false
    }

    private static func noDevice(_ settings: Settings) -> String {
        settings.say("Spotify isn't open anywhere. Open Spotify once, then ask again.", "Spotify staat nergens open. Open Spotify even, en vraag het dan opnieuw.")
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    /// Shows Spotify's login page over Dave's window.
    private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
