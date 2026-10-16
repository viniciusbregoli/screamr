<img src="assets/icon.svg" width="64" height="64" alt="">

# screamr

Voice dictation and meeting recording for macOS, transcribed by ElevenLabs Scribe. Modeled on Wispr Flow.

## Run

```sh
mkdir -p ~/.config/screamr && printf '%s' "$ELEVEN_LABS_API_KEY" > ~/.config/screamr/api_key && chmod 600 ~/.config/screamr/api_key
./build.sh && open build/Screamr.app
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

Meetings are saved to `~/Library/Application Support/Screamr/Meetings/<date>/` as `mic.m4a`, `system.m4a` and `transcript.md`. The mic channel is labeled "You" (or "Room N" when several people share the mic); call audio is diarized into "Speaker N". Use headphones on calls, otherwise the mic also picks up the other side.

## Test

```sh
swift test
```
