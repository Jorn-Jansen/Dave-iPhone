# Dave for iPhone

Dave, the voice assistant, as an iPhone app. Tap the orb and talk (English or Dutch), or type. He answers out loud, searches the web for anything current, and can hand things to [Dave on your Windows PC](https://github.com/Jorn-Jansen/Dave-Windows): "pause the music on my PC", "lock my PC", "what did I miss on Discord?".

## What he can do on the iPhone
- **Music:** "play the music", "pause", "next song", "what's playing?", "play lofi", "play my Chill playlist": Spotify
  (Premium) on whichever device it plays on, or Apple Music when you're not logged in to Spotify
- **Your PC:** "pause the music on my PC", "PC volume to 20", "lock my PC", "open Roblox on my PC", "what's on my PC screen?"
- **Apps:** "open Spotify", "search lofi in Spotify", "directions to Utrecht", "open reddit.com"
- **Shortcuts:** "run my shortcut Goodnight" (a Siri Shortcut can open any app or change settings)
- **Clipboard:** "what did I copy?", "translate what I copied", "what's in the picture I copied?"
- **Photos:** "what's in my last screenshot?", "how many photos did I take yesterday?", "show my favourites from last week"
- **Files:** "read this file", "summarise a PDF" (you pick the file)

iOS only lets apps open other apps through links (most well-known apps have one), and only lets them see files you pick.

## Install
Dave isn't in the App Store, so you sideload him with your own Apple ID:
1. Download **Dave.ipa** from the latest [release](../../releases) (or the newest run under **Actions**).
2. Install it with [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io).
   With a free Apple ID the app has to be refreshed every 7 days (AltStore can do that by itself).

## Connect to your PC
1. On the PC: Dave's settings → **iPhone app** → turn on and save. The address and code show up there.
2. In the app: settings (⚙) → fill in the address and code → **Connect to my PC**.
   This also copies your Groq key, name and language, so you don't have to type them.

The phone and PC need to be on the same Wi-Fi. To use it outside your home, install [Tailscale](https://tailscale.com) on both and use the PC's Tailscale address (100.x.x.x).

## Spotify
1. On [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → your Spotify app (the one Dave on the PC uses) →
   **Settings → Edit → Redirect URIs**: add `dave-iphone://spotify-callback` and save.
2. In the app: settings (⚙) → **Log in to Spotify**. (Connecting to your PC fills in the Client ID.)

Without a PC, paste your own free Groq key from [console.groq.com/keys](https://console.groq.com/keys) in the settings.

## Building
The app is built on GitHub's Macs (`.github/workflows/build.yml`): every push to `main` makes an unsigned `Dave.ipa`. The Xcode project is made from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
