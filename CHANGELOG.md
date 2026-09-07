# Changelog

All notable changes to OpenClaw Mobile are recorded here. Versions follow the
4-digit `MAJOR.MINOR.PATCH.MICRO` form in `VERSION`.

## [0.2.0.0] - 2026-09-07

### Added
- Send photos, camera shots, and files to an agent from the composer. Images are resized once
  and sent as JPEG; small source and text files are pasted into the message as a code block so
  the agent reads them directly; anything over the gateway's limits is refused with a reason
  before it leaves the phone.
- Dictate a message with the mic button. Recognition runs on the device when the language
  supports it, typed text is kept, and a denied permission shows how to fix it.
- Stop a running agent reply from the composer; the bubble is marked "Stopped" rather than failed.
- Retry a message that failed to send.
- Code in agent replies renders as real code blocks with a Copy button; inline markdown
  (bold, italic, inline code, links) renders in prose. Long-press a message to copy or share it.
- A collapsible tool-call timeline under the current reply shows what the agent actually ran
  (`Bash: ls`, `Read: Sources/App.swift`), straight from gateway signals.

### Changed
- The whole app now uses the official OpenClaw palette (lobster red on blue-black), 6 pt
  controls and 10 pt cards, system type for the interface and monospace only for code, ids,
  and paths. Every screen was restyled; status chips carry an icon, never colour alone.
- Chat threads are addressed by gateway session, so future task threads of the same agent
  can open alongside its main thread.
- The camera, photo library, microphone, and speech permission prompts explain what each
  is used for.

### Fixed
- Stopping is only disarmed by the run that actually ended, so a late signal from an earlier
  reply can no longer hide the Stop button for a newer one. Sending is blocked while a run is
  active instead of silently queueing behind it.
- A picked file is checked by size before it is read, so a multi-gigabyte pick cannot exhaust
  memory.
- Markdown files that contain their own code fences are attached as files instead of being
  inlined into a fence they would break.
- The debug wire log no longer contains photo bytes.
