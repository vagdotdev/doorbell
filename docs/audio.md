# Audio: noise, and what to do about it

Most of what a laptop microphone picks up is not the person. Fans, a kitchen, traffic, keyboard, the room itself. On Doorbell this matters twice: in the room, like any call, and on the doorstep — the first thing you hear from someone at your door is their microphone, at door volume, through the peephole. If that is hiss and clatter, the knock feels bad before anyone has said a word.

This page is what we have, what we researched, and the order to do the rest in.

## What is on today

One microphone pipeline, everywhere. The knocker's doorstep seat and every room seat are the same `MediaSession` with the same capture options, so anything here applies to knocks exactly as much as to rooms.

**LiveKit capture processing** (`MediaSession.swift`, `AudioCaptureOptions`):

| Stage | State | What it does |
|---|---|---|
| Echo cancellation | on | Stops your speakers coming back down your mic. |
| Noise suppression | on | Stationary noise — fan, hum, hiss. |
| Auto gain control | on | Quiet talkers come up, loud ones come down. |
| High-pass filter | on | Takes room rumble and desk thumps off the bottom. |

Each is in `.automatic` mode: LiveKit uses Apple's Voice Processing I/O when the platform offers it (macOS does) and falls back to WebRTC's software processing otherwise. The first three are LiveKit's defaults; we turned on the high-pass explicitly.

**macOS Voice Isolation** (`SettingsView.swift`, Settings → Microphone):

macOS 12+ has a system-wide microphone mode — Standard, Voice Isolation, Wide Spectrum — that applies to any app using Apple voice processing, which we do. Voice Isolation is Apple's ML voice separator; it is very good and costs us nothing. Apps cannot set it, only the user can, from Control Center while the mic is live. Settings → Microphone shows the current mode and opens the system picker (`AVCaptureDevice.showSystemUserInterface(.microphoneModes)`). The modes are only selectable while a mic is actually capturing, so the picker is most useful from inside a room or while knocking; from an idle app it shows the current mode greyed out.

Because of that, the first time this Mac's microphone goes live for a door — the first knock or walk-in — and the mode is still Standard, the picker opens once by itself (`MicrophoneMode.nudgeOnce`). Voice Isolation is then one click away at the exact moment it can be chosen. It never asks again; the choice is the system's and persists across every app.

Between these two, a Mac in a normal room sounds close to what people expect from Meet or FaceTime.

## What we researched and did not add

**Krisp** (`livekit/swift-krisp-noise-filter`). LiveKit's own noise filter, the same one Meet-class products license. It plugs in as `AudioManager.shared.capturePostProcessingDelegate` and would be a few lines. It is a LiveKit Cloud feature: the plugin fetches its model and license through the Cloud connection and does not run against a self-hosted `livekit-server`. We are self-hosted (local dev today, our own server or Cloud later). If we move to LiveKit Cloud, add it — it is the single biggest quality step available and needs no other change.

**RNNoise / DeepFilterNet** (open models). Either can run in the same `capturePostProcessingDelegate` slot: LiveKit hands us 10 ms PCM frames, we hand back cleaned ones. RNNoise is tiny and cheap (a few % of one core), older, decent on stationary noise, weak on transients. DeepFilterNet is much better and still real-time on Apple silicon, but means shipping a Core ML or ONNX model and writing the resampling and framing glue. This is the self-hosted route to Krisp-level results. Not quick: a few days including listening tests.

**Receiver-side processing.** We could denoise what we *hear* instead of what they send. Worse in every way — you pay per remote participant, you cannot fix what compression already ate — except one: it works on people running an old client. Not worth it for a product this young.

**Peephole EQ.** The doorstep already applies a low-pass so door volume reads as "through a door" (`DesignTokens.doorVolume`, `IncomingAudio`). That is texture, not cleanup; it does not replace the above and should not try to.

## Order of work

1. **Now (done):** LiveKit's four stages on, high-pass included, one pipeline for doorstep and room. Settings → Microphone surfaces Voice Isolation.
2. **On LiveKit Cloud:** add `LiveKitKrispNoiseFilter` as the capture post-processing delegate. Gate it on `room.url` being a Cloud host so self-hosted builds keep working.
3. **If we stay self-hosted and want more:** DeepFilterNet via Core ML in the post-processing delegate. Ship behind a setting, off by default, until listening tests say otherwise.
4. **Measure before 3:** record a fixed clip (voice + fan + typing) through each configuration and listen blind. Noise suppression is easy to over-apply and the failure mode — a voice that sounds underwater — is worse than a little hiss.

## Invariants

- Processing happens on the sender's Mac. Nothing about audio leaves the device except the encoded track the person chose to publish. No server-side audio processing, no recordings, no "quality analytics."
- Whatever runs on the doorstep runs in the room, and vice versa. The knock is not a lower-quality mode.
