<img src="assets/AppIcon.png" width="96" height="96" alt="screamr icon">

# screamr

Voice dictation and meeting recording for macOS, transcribed by ElevenLabs Scribe. Modeled on Wispr Flow.

## Run

```sh
mkdir -p ~/.config/screamr && printf '%s' "$ELEVEN_LABS_API_KEY" > ~/.config/screamr/api_key && chmod 600 ~/.config/screamr/api_key
./build.sh install   # builds, copies to ~/Applications (Raycast/Spotlight) and launches
```

The key can also come from the `ELEVEN_LABS_API_KEY` environment variable. Requires macOS 14.4+.

First launch asks for **Accessibility** (hotkeys and pasting; relaunch after granting), then **Microphone** and **System Audio Recording** on first use. In System Settings > Keyboard, set "Press Globe key to" to "Do nothing" so Fn doesn't open the emoji picker.

## Shortcuts

| Keys | Action |
|---|---|
| Hold Fn | Dictate, release to paste |
| Double-tap Fn, or Fn+Space | Hands-free dictation, Fn again to finish |
| Esc | Cancel dictation |
| Ctrl+Opt+Cmd+M | Start or stop a meeting recording |
| Ctrl+Opt+Cmd+D | Open the dashboard (or open the app again) |

## Dashboard

Home (stats and dictation history), Meetings (transcripts, re-transcribe), Dictionary, Snippets and Settings, in Catppuccin Mocha. Inside it: Cmd+1 to Cmd+5 switch sections, Cmd+K opens the command palette, `/` searches history, `?` lists shortcuts, Cmd+N adds an entry, Cmd+Plus / Cmd+Minus / Cmd+0 zoom, Esc closes.

Dictionary words are sent to Scribe as key terms. A replacement also rewrites what Scribe heard, which is how to fix names that sound like common words (Screamer to screamr). Snippets expand a spoken trigger phrase into text. Data lives in `~/Library/Application Support/Screamr/`.

Meetings are saved to `~/Library/Application Support/Screamr/Meetings/<date>/` as `mic.m4a`, `system.m4a` and `transcript.md`. The mic channel is labeled "You" (or "Room N" when several people share the mic); call audio is diarized into "Speaker N". Use headphones on calls, otherwise the mic also picks up the other side.

## Test

```sh
swift test
```
