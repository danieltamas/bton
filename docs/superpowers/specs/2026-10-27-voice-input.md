# Voice input for a new issue

Date: 2026-10-27. Status: proposed, not started. Asked by Dani after New issue shipped: speaking
to Bton as well as typing, "proper voice to text", with a small open model.

## Problem

Writing the first description and every answer to the agent's questions is typing on a small
text box in a menu-bar popover. Speaking is faster, and the answers to "one row per invoice or per
line item?" are naturally spoken.

## Change

A mic button beside Send in the New issue input (and later the Draft reply box). Press to start,
press again to stop; the words land in the text box, editable, and nothing is sent until Send.
The audio never leaves the Mac and is never kept; the agent only ever receives the text.

- Engine: WhisperKit (Argmax, MIT, Swift Package, Core ML on the Neural Engine) running OpenAI
  Whisper models. Default `large-v3-turbo` (best accuracy, fast enough on Apple Silicon), with
  `small` as the lighter choice in Settings. Whisper covers Romanian and English, the two
  languages Dani writes in; the language is detected per recording unless pinned in Settings.
- Not Apple's SpeechAnalyzer: it needs macOS 26 and Bton targets macOS 14.
- Alternative to evaluate in the same spike: NVIDIA Parakeet TDT v3 (25 European languages, said
  to include Romanian: verify) through a Core ML port. Pick by word error rate on 10 real
  recordings of Dani's own issues, Romanian and English, not by reputation.
- Models download on first use into `~/.bton/models/` (a few hundred MB to about 1.5 GB), with
  progress in Settings > Voice and a hash check; never bundled in the app.
- Capture: `AVAudioEngine`, resampled to 16 kHz mono, in memory; a silence gate ends a
  recording that was left on; hard cap 5 minutes.
- Streaming: partial text appears while speaking only if the chosen engine supports it without
  hurting accuracy; otherwise the text appears when recording stops (acceptable: a spoken answer
  is seconds long).

## Constraints

- Microphone permission: `NSMicrophoneUsageDescription` in the bundle's Info.plist and the
  `com.apple.security.device.audio-input` entitlement in `scripts/bundle.sh`'s signing step; the
  first press shows the system prompt. The prompt takes focus and may close the popover: the
  session state (`NewIssueSession`) already lives in `AppStore`, so the conversation survives.
- Third-party code: WhisperKit, its dependencies and every model are fetched and read in the
  `inspect` sandbox first, per the fleet rule. Pin versions and model hashes in Package.resolved
  and in a `Voice.models` table.
- No network at recording time. Only the one-time model download touches the network, from the
  host the model card names, over HTTPS, size and hash checked, refused on mismatch.
- Off by default; Settings > Voice switches it on, picks the model and the language.

## Acceptance

1. With the model downloaded and the network off, pressing the mic, saying a Romanian and an
   English sentence, and pressing again puts both in the text box within 3 seconds of stopping
   (turbo) on an M-series Mac, with word error rate at or below 10% on the 10 recorded samples.
2. No audio file exists on disk after a recording (checked by listing `~/.bton` and the temp
   directory); nothing is sent before Send.
3. Denying the microphone shows one line saying so and how to allow it; the mic button never
   crashes or hangs.
4. The release's `bundle.sh` output carries the entitlement and usage string (checked with
   `codesign -d --entitlements -` and `plutil`), and the model download is refused on a wrong hash.
5. A unit test covers the model table (hash, size, language set) and the silence gate; the
   recorder and engine sit behind a protocol so the New issue view is tested with a fake that
   returns canned text.

## Open questions

- Hold-to-talk versus click-to-toggle: toggle first (hands free while reading the agent's
  questions), hold as an option.
- A global hotkey to dictate into the open box: later, needs Accessibility permission.
- Whether dictation also cleans up filler words: no, the text is the words spoken; the agent
  that writes the issue does the tidying.
