# Voice E2E fixture

`voice-idea.oga` is the speech sample the voice-note idea-capture E2E
(`run_idea_e2e.sh` with `TG_IDEA_MODE=voice`, driven by `drive_idea.py` →
`_drive.drive_voice`) sends to the bot as a Telegram voice note. The bot
downloads it, transcribes it through the real Whisper API, and the driver
asserts the transcript contains `TG_VOICE_EXPECT` (default `voice idea`).

## Contract

- **Filename:** `voice-idea.oga` (the default `TG_VOICE_FIXTURE`); override
  with `TG_VOICE_FIXTURE=/path/to/other.oga`.
- **Format:** Ogg/Opus voice note (what Telegram and Whisper accept for the
  `audio/ogg` voice path the supervisor uses).
- **Content:** a real human or TTS recording clearly speaking the words
  **"voice idea"** (or whatever `TG_VOICE_EXPECT` is set to). It MUST be
  genuine speech — a silent clip or a tone makes Whisper return `no_speech`
  and the E2E fails, which is the point: this fixture is not a stub.

## Why it isn't auto-generated

The E2E gate is intentional: when `HIVE_WHISPER_API_KEY` is **unset** the
voice mode skips (matching the `HIVE_TEST_BOT_TOKEN` convention); when the
key **is** set, a missing fixture is a hard FAIL rather than a silent skip
(`drive_idea.py`). Generate the clip once with any TTS that produces
Ogg/Opus, e.g.:

```sh
# espeak-ng + ffmpeg (Linux); or `say` on macOS, then convert.
espeak-ng "voice idea" -w /tmp/voice-idea.wav
ffmpeg -i /tmp/voice-idea.wav -c:a libopus -b:a 24k \
  test/fixtures/voice/voice-idea.oga
```

Check the resulting `voice-idea.oga` in next to this README so the
secret-gated E2E can run end-to-end.
