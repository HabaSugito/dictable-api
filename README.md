# Dictable API

**A menu bar app that turns macOS's on-device speech recognition into a local API.**
OpenAI-compatible file transcription over HTTP, plus live streaming transcription over WebSocket. Free, offline, and private: audio never leaves your Mac.

**Website:** https://dictable.dev

> **Free.** Dictable API is free to download and use, with no account, no API key, and no usage limits. Recognition runs on your Mac, so there are no per-minute charges like a cloud API. MIT-licensed, so it can be used in commercial projects too.

```
┌──────────────┐  POST /v1/audio/transcriptions   ┌───────────────────────────┐
│ OpenAI SDK,  │ ───────────────────────────────▶ │        Dictable API        │
│ curl, apps   │ ◀─────────────── {"text": …}     │   (menu bar, 127.0.0.1)   │
└──────────────┘                                  │                           │
┌──────────────┐  ws://…/v1/stream  PCM ▶        │  SpeechAnalyzer +          │
│ Browser,     │ ───────────────────────────────▶ │  SpeechTranscriber         │
│ extensions   │ ◀── partial / final results ──── │  (macOS 26, on-device)     │
└──────────────┘                                  └───────────────────────────┘
```

## Why

macOS 26 ships a fast, accurate on-device speech model (`SpeechAnalyzer`), but it is only reachable from Swift.
Dictable API exposes it to every language and tool you already use:

- **Drop-in for the OpenAI transcription API.** Change `base_url` and existing code works unchanged.
- **Live captions.** Partial results arrive while the person is still speaking (about 1 s behind), and each sentence is finalized as soon as it ends.
- **No model downloads to manage, no GPU, no API bill.** The OS downloads and updates language models on first use.
- **Zero dependencies.** HTTP/1.1 and WebSocket (RFC 6455) are implemented directly on `Network.framework`.

Measured on a MacBook Air (M-series, 16 GB) with a 24-second English clip: the whole file transcribes in about 1.4 s. In streaming mode, the first words appear about 1 s after speech starts, and each sentence is final about 0.2 s after it ends.

## Use cases

### Real-time translation

Caption a video call, webinar, or YouTube video in another language as people speak.

```
tab / mic audio → Dictable API (WebSocket) → translation model → live subtitles
```

- Show `partial` text while people talk, then replace it with the translation when each `final` sentence arrives. Sentences are final about 0.2 s after they end, so subtitles follow the speaker closely.
- Pair it with a local translation model (for example PLaMo Translate on llama.cpp) to keep the whole pipeline offline.
- Browser extensions can connect directly, because extension origins are allowed by default (see [Security](#security)).

### Meeting notes and minutes

Turn meetings, interviews, and lectures into transcripts, then summarize them into minutes, without sending confidential audio to a cloud service.

```
recording or live audio → Dictable API (HTTP or WebSocket) → summarizing LLM → minutes
```

- `response_format=verbose_json` returns sentence-level timestamps, so the minutes can link back to the moment each point was made.
- `srt` / `vtt` output adds captions to the meeting recording.
- It uses the OpenAI SDK, so existing transcription and summarization code works by changing `base_url`.

## Requirements

- macOS 26 (Tahoe) or later on Apple silicon
- Xcode 26 to build from source

## Install

Download `DictableAPI-x.y.z.zip` from [Releases](../../releases), unzip, and move **Dictable API.app** to Applications.
It is signed with a Developer ID and notarized by Apple, so it opens with a double-click.

Or build it yourself:

```bash
git clone https://github.com/HabaSugito/dictable-api.git
cd dictable-api
./scripts/build-app.sh
open "build/Dictable API.app"
```

`build-app.sh` signs with the first *Developer ID Application* certificate in your keychain (or ad-hoc if there is none). To also notarize, store credentials once with `xcrun notarytool store-credentials dictable-notary --team-id <TEAM_ID>`; every build is then notarized and stapled.

A waveform icon appears in the menu bar. Click it to see the endpoints and live activity. **Settings…** at the bottom holds the port and **Start automatically when I log in**. For that option, keep the app in /Applications so the login item keeps pointing at it.

### Changing the port

The default port is `8082`. If another app already uses it, Dictable API does not start on it. The menu shows the clash and offers the next free port, which you can accept with **Use port 8083 instead**. You can also open **Settings…** and type any port from 1024 to 65535 in the **Port** field. Remember to point your clients at the new port too.

If you switch back to a port that another app has just released, macOS may hold it for up to about 30 seconds. Dictable API shows that it is waiting and starts on its own when the port is free.

From the command line: `defaults write io.github.habasugito.DictableAPI port -int 9000`, then restart the app.

## HTTP API (OpenAI-compatible)

Base URL: `http://127.0.0.1:8082/v1`

### `POST /v1/audio/transcriptions`

Same request format as [OpenAI's endpoint](https://platform.openai.com/docs/api-reference/audio/createTranscription) (`multipart/form-data`).

| Field | Notes |
|---|---|
| `file` | Required. Any format AVFoundation reads: wav, m4a, mp3, aiff, caf… |
| `language` | `en`, `ja`, `en-GB`, `ja_JP`… Defaults to the system language. Automatic language detection is not supported. |
| `response_format` | `json` (default), `text`, `verbose_json` (with segments and timestamps), `srt`, `vtt` |
| `model` | Accepted and ignored: the on-device model is always used |

```bash
curl http://127.0.0.1:8082/v1/audio/transcriptions \
  -F file=@meeting.m4a -F language=ja -F response_format=srt
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8082/v1", api_key="not-needed")
with open("meeting.m4a", "rb") as f:
    print(client.audio.transcriptions.create(model="apple-on-device", file=f, language="en").text)
```

### Other endpoints

| Endpoint | Returns |
|---|---|
| `GET /health` | `{"status":"ok","version":"…"}` |
| `GET /v1/models` | The single model id, `apple-on-device` |
| `GET /v1/locales` | Supported locales, and those already downloaded on this Mac |

Errors use OpenAI's shape: `{"error": {"message": "…", "type": "…"}}`.

## WebSocket streaming API

Connect to `ws://127.0.0.1:8082/v1/stream`.

| Direction | Message |
|---|---|
| server → client | `{"type":"hello","server":"dictable-api","version":"1.0.0"}` |
| client → server | `{"type":"start","language":"ja-JP","sample_rate":16000}` |
| server → client | `{"type":"status","message":"Downloading the speech model…"}` (first use of a language only) |
| server → client | `{"type":"ready","locale":"ja_JP"}` |
| client → server | **binary**: 16-bit little-endian mono PCM at `sample_rate` (any chunk size; 100 ms works well) |
| server → client | `{"type":"partial","text":"…"}`: the unfinished text since the last final; it is replaced by later messages |
| server → client | `{"type":"final","text":"…","start":1.38,"end":3.54}`: finalized text with timestamps in seconds |
| client → server | `{"type":"stop"}`: finalizes the remaining audio; the server answers `{"type":"stopped"}` |

Shortcut: `ws://127.0.0.1:8082/v1/stream?language=en-US&sample_rate=48000` starts immediately without the `start` message.

## Examples

| File | What it shows |
|---|---|
| [`examples/openai_sdk.py`](examples/openai_sdk.py) | The official OpenAI Python SDK with segment timestamps: `uv run --with openai examples/openai_sdk.py talk.m4a en` |
| [`examples/curl.sh`](examples/curl.sh) | Every HTTP endpoint and output format |
| [`examples/stream_file.mjs`](examples/stream_file.mjs) | Streams a WAV file in real time and prints partial and final results (Node 22+) |
| [`examples/mic.html`](examples/mic.html) | Live captions from your microphone in the browser |

## Security

The server binds to `127.0.0.1` only. Web pages you visit can still try to reach localhost, so Dictable API also:

- requires a loopback `Host` header, which blocks DNS-rebinding attacks;
- rejects browser requests unless their `Origin` is a browser extension (`chrome-extension://`, `moz-extension://`, `safari-web-extension://`) or a `localhost` page. Clients that send no `Origin` (curl, SDKs, native apps) are allowed.

## Project layout

```
Sources/DictableCore/        UI-free library, unit tested
  Server.swift           NWListener, routing, per-connection HTTP → WebSocket upgrade
  HTTP.swift             HTTP/1.1 request parser and response writer
  WebSocket.swift        RFC 6455 framing, handshake key, fragment reassembly
  Multipart.swift        multipart/form-data parser (OpenAI SDK uploads)
  SpeechEngine.swift     SpeechAnalyzer streaming + file transcription, model download
  Security.swift         Host / Origin checks
  Subtitles.swift        SRT / VTT output
Sources/DictableAPI/      SwiftUI MenuBarExtra app
Tests/DictableCoreTests/     Swift Testing suites for the parsers and policies
scripts/build-app.sh     Builds and zips the .app bundle
site/, worker/           Landing page for https://dictable.dev (Cloudflare Workers): `npx wrangler deploy`
```

```bash
swift test               # unit tests
swift run DictableAPI     # run without bundling (debug)
```

## Limitations

- No automatic language detection: the on-device model needs a locale.
- One model ("apple-on-device"). `prompt` and `temperature` are ignored.
- `timestamp_granularities=word` is not supported; `verbose_json` returns sentence-level segments.

## License

[MIT](LICENSE)
