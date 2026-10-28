# Voice Agent

Select **Voice Agent** below **Tool Use** to run the voice agent ported from
ailia-models-kotlin. Choose Whisper Medium (default) or Large V3 Turbo, Gemma 4
E2B (default) or E4B, and a separate backend for recognition, responses and
GPT-SoVITS V2-Pro Distill Base synthesis. MTP defaults to on for E2B and off for
E4B; each model remembers its setting while this screen is open. The QNN choices
follow this Flutter app's existing platform/SoC support (converted Speech and
LLM models on supported Windows ARM64 devices; synthesis runs on CPU/GPU).
Unsupported model/backend combinations disable MTP or fall back to CPU.

Press **開始** and allow microphone access. Japanese speech passes through
Silero VAD v6.2, Whisper, Gemma's structured tool API and response synthesis.
About one second of silence ends a turn, or use **送信** to submit manually;
recordings are limited to 30 seconds. The microphone pauses during processing
and playback and resumes automatically, excluding 400 ms of playback settling
audio. The black call screen shows a PCM-driven white orb and the latest input
and response. Its animation ports the Kotlin view's 12 PCM sections, asymmetric
energy smoothing, 180 ms stale-audio decay, state-dependent integrated motion,
48 outline points and closed Catmull-Rom curve, with solid white on black.
Microphone PCM and 50 ms clips sampled from playback position drive the same
animation; playback position is polled every 40 ms. Use **応答を中断** to return to
listening, **×** or Back to end the
session. Backgrounding the app also stops capture and playback.

Two tools are available: `set_air_conditioner_temperature` changes sample state
(for example, 「エアコンを20度にして」), and `take_photo` takes a photo using the
selected camera (「写真を撮影してください」). On mobile, choose rear/front or an
explicit device. On desktop, choose the system default or an available camera
(including external USB cameras). Press **カメラ一覧を取得** to populate/refresh
the **撮影デバイス** selector. Enumerating devices can request camera permission;
simply opening settings does not. Without enumeration, permission is requested
when a photo is needed. An explicit device overrides rear/front selection and
is retained for the session; a disconnected selection reports an error instead
of silently capturing from another camera. The temperature and latest thumbnail
appear during the
call. Bounded, upright JPEG data stays in conversation history for follow-up
questions; temporary capture/playback files are deleted. History keeps recent
turns, retains complete tool exchanges
when compacting near the context limit, and continues long answers internally.
Tool syntax is filtered from streaming text and speech. Synthesis runs beside
generation on its own isolate and queues punctuation-delimited phrases;
playback begins after generation, with at most two finished clips waiting.
Cancellation joins native synthesis before the next recognition turn.

Turn off **応答の音声合成** for text responses. In microphone mode this also skips
voice model downloads. **テスト：GPT-SoVITS合成音声** synthesizes one query per line
and feeds its PCM through the same VAD/recognition path without microphone
access. Voice synthesis remains enabled for test inputs. Query text is never
sent directly to Gemma. After the final response the last turn stays visible;
interrupting switches to microphone mode. The first start downloads models
and dictionaries; allow several GB of storage and memory.

Unit and widget checks: `flutter test test/voice_agent_test.dart test/voice_agent_widget_test.dart test/voice_agent_download_test.dart`.
Camera/animation checks: `flutter test test/voice_agent_camera_test.dart test/voice_agent_orb_test.dart`.
The animation fixture executes the original Kotlin `VoiceAgentOrbView.kt` with
a controlled clock and recording canvas; all 48 points, 12 PCM levels, energy
and phase are compared across 15 frames, allowing Float/Double rounding.
The opt-in native test runs two synthesized queries through VAD, Whisper,
Gemma with MTP and response synthesis, using cached Turbo/E2B/Distill Base
models. It writes `voice-agent-native.json` in the system temporary directory.
It verifies PCM generation without opening the microphone or audio device.
On macOS, after building the app, run:

```sh
DYLD_LIBRARY_PATH="$PWD/build/macos/Build/Products/Debug/ailia_models_flutter.app/Contents/Frameworks" \
AILIA_VOICE_AGENT_MODEL_DIR="$HOME/Documents/ailia MODELS flutter/models" \
"$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" \
"$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" test --no-pub test/voice_agent_native_test.dart
```

The native test prefers Metal on macOS; `AILIA_VOICE_AGENT_BACKEND=CPU` selects
CPU. Hardware microphone, speaker and camera behavior should also be checked
on the target device.
