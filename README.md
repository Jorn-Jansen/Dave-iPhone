# Dave for iPhone

Dave, the voice assistant, as an iPhone app. Tap the orb and talk (English or Dutch), or type. He answers out loud, searches the web for anything current, and can hand things to [Dave on your Windows PC](https://github.com/Jorn-Jansen/Dave-Windows): "pause the music on my PC", "lock my PC", "what did I miss on Discord?".

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

Without a PC, paste your own free Groq key from [console.groq.com/keys](https://console.groq.com/keys) in the settings.

## Building
The app is built on GitHub's Macs (`.github/workflows/build.yml`): every push to `main` makes an unsigned `Dave.ipa`. The Xcode project is made from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
