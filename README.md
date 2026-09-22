# MyNotch

A dynamic notch for macOS — the black area around your MacBook's camera becomes a
little dashboard. Hover it and it grows slightly; click and it opens.

<img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">

## What it does

- **Mirror** — live front-camera view, mirrored like a real mirror.
- **Music** — album art and an animated EQ appear right in the notch whenever
  anything is playing (Apple Music or Spotify). Click through to a spinning
  vinyl record you can **grab and spin to scrub** the track, with a tape-whir
  sound while you do. Play/pause straight from the album art.
- **Shelf** — drag files onto the notch, switch Spaces or apps, and drag them
  back out wherever you need them.
- **Calendar** — today's events, with a handle to expand for more.
- Starts at login, updates itself, and lives in your menu bar.

## Install

1. Download **MyNotch.dmg** from [Releases](../../releases/latest).
2. Drag MyNotch to Applications.
3. **Right-click it in Applications → Open → Open.** You only do this once —
   the app is signed, but not notarized (that needs a paid Apple Developer
   account), so macOS asks for confirmation on the first launch. A normal
   double-click will be refused.
4. Approve the Camera, Calendar, and "control Music" prompts as you use each tab.

If macOS ever calls the download damaged, clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/MyNotch.app
```

## Using it

| Action | What happens |
| --- | --- |
| Hover the notch | Grows slightly, with a haptic tick |
| Click the notch | Opens the panel |
| Move the mouse away | Closes instantly |
| Drag files onto the notch | Opens the Shelf and drops them in |
| Click album art on the island | Play / pause without opening |
| Drag the vinyl record | Scrubs the track (one turn ≈ 25s) |
| Menu-bar icon | Toggle, Open at Login, Check for Updates, Quit |

## Building from source

Needs only the Xcode **Command Line Tools** — no full Xcode.

```bash
./setup_signing_identity.sh   # once: creates a local signing certificate
./build.sh                    # builds build/MyNotch.app
./build_dmg.sh                # also packages dist/MyNotch.dmg
```

`setup_signing_identity.sh` matters more than it looks: ad-hoc signing pins
macOS's permission grants to the exact binary hash, so every rebuild would reset
Camera/Calendar/Automation access. Signing with a stable certificate keeps them.

### Releasing an update

```bash
./release.sh 1.1.0 "Added the file shelf"
```

That bumps the version, builds, tags, pushes, and attaches the DMG to a GitHub
release. Everyone running MyNotch is offered the update within a day (or
immediately via **Check for Updates…**), and it installs and relaunches itself.

## Notes

- Built with SwiftUI + AppKit against the Command Line Tools, so it avoids
  SwiftUI's macro-based property wrappers (`@State`) and uses `ObservableObject`
  throughout — the macro plugin ships only with full Xcode.
- Now-playing data comes from scripting Music/Spotify directly. macOS restricts
  the private MediaRemote framework to Apple-signed apps, so that route isn't
  available to third-party apps.

## License

MIT
