<img src="Resources/AppIcon.png" width="128" alt="CallTap icon">

# CallTap

A macOS menu bar app that records WhatsApp calls made on the Mac. When a call starts it shows a
notification with a **Record** button; the recording stops and is saved when the call ends, as one
`.m4a` in `~/Documents/CallTap Recordings`.

**Tell the other person you are recording.** Recording a conversation without consent is illegal
in many places.

## How it records

- **The other side** comes straight from WhatsApp's own audio output, through a Core Audio process
  tap (macOS 14.2+), so it keeps WhatsApp's full quality and nothing else on the Mac is captured.
- **Your side** comes from the Mac's current default input.
- Each side is written to its own temporary file and mixed into the final `.m4a` when the call
  ends. If the mix fails, both raw tracks are kept next to where it would have been saved.

A call is detected while WhatsApp is capturing microphone input. Recording a voice message looks
the same from outside, so it also triggers the prompt.

### Call quality with Bluetooth headphones

Using a Bluetooth headset's microphone forces it into the hands-free profile, which degrades the
audio in both directions — on any call, recorded or not. Choose the Mac's microphone as input in
System Settings › Sound (or in WhatsApp's call settings) and keep the headphones for listening only.
The menu shows which input is in use and warns when it is a Bluetooth one.

## Permissions

macOS asks once for each: notifications, the microphone (your side), and **System Audio Recording**
(the other side). Without the last one the tap records silence instead of failing. Saving into
Documents may also ask for folder access.

## Build and run

```bash
./scripts/build-app.sh --install  # builds and copies CallTap.app to ~/Applications
swift test                        # unit tests (naming, track alignment)
./scripts/make-icon.sh            # regenerates Resources/AppIcon.icns
```

The app is ad-hoc signed; each rebuild changes its signature, so macOS asks for the permissions
again after reinstalling.
