# ScriptMax

A native macOS teleprompter with a floating prompt, on-device English speech following, and experimental webcam gaze positioning.

## Set up on another Mac

See [SETUP.md](SETUP.md) for prerequisites, build commands, first-launch permissions, and an agent-ready setup checklist. This version requires an Apple Silicon Mac running macOS 27 or newer; Windows and Intel Macs are not supported by this setup.

## Use

Open `build/ScriptMax.app`. Paste your script, choose a maximum of 4–10 words (default 10), and click **Start from beginning**. Allow Microphone access when macOS asks. The prompt floats above ordinary apps and follows your speech. Words disappear individually as they are recognized, with upcoming text below. Drag the prompt by its background. Use its pause, back, next, pin, and close buttons.

For gaze positioning, choose **Calibrate eyes**, allow Camera access, and look at each of the five dots for about 1.4 seconds, followed by a center-point check, with your head steady. Calibration waits when it cannot see both eyes, and rejects inconsistent samples or a failed center check. The prompt stays within the display where calibration ran, smooths movement, and holds its position when eyes are lost. Recalibrate after moving your head, camera, display, or seating position. Turn off **Follow my gaze** or click the overlay pin to use a steady near-camera prompt.

A webcam estimates pupil position; it is not a dedicated eye tracker. Lighting, glasses, blinking, and head movement affect accuracy. A small fixed prompt near the camera generally gives better eye contact. The overlay may appear in full-screen screen recordings and screen sharing; share a specific app window when appropriate.

## Recognition

Uses NVIDIA Nemotron Speech Streaming 0.6B (600M) through FluidAudio, pinned in Package.swift. The streaming CoreML model processes 560 ms chunks, with incremental token callbacks; 160 ms is the input window, not a guaranteed end-to-end delay. Inference uses CPU and Apple Neural Engine, with no cloud recognition, recordings, analytics, or saved transcripts. Models download once from FluidInference's Hugging Face repository into `build/SpeechModels` beside the app and are reused locally. The pasted script stays in app preferences.

Exact next-word matches advance from partial text. Strong left-side script context and a distinctive right anchor can recover through one or two misheard script words or short inserted fragments, including the reported “essential attacked detectives” recognition error. A plausible substitution needs a matching right word; an unrecognizable substitution needs two right-side words. A lone coincidental word does not release unrelated speech. Stable transcript prefixes reuse cached matching states, with a short tail rechecked for new context and recognition revisions. Near spellings need neighboring script evidence; moving elsewhere requires a matching phrase, including earlier phrases for backward re-sync. Ambiguous repeated phrases hold. The streaming API does not expose calibrated word-confidence scores through this API, so script similarity and phrase context supply the confidence gate. The whole script is not fed as a forced transcript, and predictive pacing/raw word counting are disabled. Actual live latency and accuracy need testing on the user's voice and microphone.

## Compact overlay

Compact overlay is enabled by default. Each box hugs its two text lines, with a small margin and no large empty square or shadow. Choose a maximum of four to ten words, displayed on up to two lines, and adjust the largest text size from 8 to 44 points. The size-range control permits only 80–100% of that size, with an absolute minimum of 8 points. The box grows as the maximum-word setting rises above six. The Box width slider adds reading space when more words are needed while speech recognition catches up. The preview tries the selected maximum at full size, then shows fewer words when they are crowded, before using the permitted font range. Word-limit and box-size choices are saved across app restarts. Exceptionally long words appear with fewer neighbors or alone; a single oversized word expands the square rather than shrinking. Withheld neighbors remain in the script and appear as reading advances. Only width expands to accommodate additional words; height stays at two text lines. Seven synchronized prompt boxes are enabled by default: six around the screen plus one centered on the full display. All three top-row boxes sit one display point below the notch safe area, with text aligned to the top. The single-box mode uses the same camera-adjacent placement. Each box can be dragged independently. Arrange seven boxes restores their placement; stopping hides all boxes. Turn off Seven prompt boxes for one prompt and optional gaze positioning. Compact mode shows just the current words; hover to reveal pause and drag its background to move it. The editor retains start, pause, stop, font-size and placement controls. Turn off Compact overlay to show upcoming text and the full overlay controls.

Microphone capture uses direct AVCapture audio sample buffers instead of an AVAudioEngine tap. The app only reports Listening after microphone audio enters the streaming queue. Camera and microphone frames are processed locally and never saved.

## Build and checks

Requires Xcode 27 command-line tools and macOS 27 or newer on Apple Silicon. The first build fetches the pinned Swift package dependency; first recognition fetches model files. Build on your Mac with `./scripts/build.sh`, then open `build/ScriptMax.app`. This produces a locally ad-hoc-signed app; distribution to other Macs requires developer signing and notarization. Run `./scripts/test.sh` for script-following and calibration math checks.

Live camera accuracy, microphone following, other-app overlay behavior, and long-session recognition must be checked on real use. Automated checks and a successful build do not establish these behaviors.

## Practice script

`Practice-Script.txt` contains a short, natural practice talk about starting with small steps.

## Recognition validation

The exact screenshot transcript containing “essential attacked detectives” is a regression case: it recovers at detectives and continues to play recordings. Tests cover conservative holds, low-confidence bridges, singular/plural variants, revised partial text, backward re-sync, and cached-versus-full-replay equivalence.

Models were compared on the same synthesized 52-word presentation excerpt, fed at real-time speed. Parakeet produced 6 normalized word edits (11.5%); Nemotron produced 0. Punctuation/case/apostrophes were excluded from that comparison. Nemotron delivered 28 live updates and the matcher reached 52/52 words. Inference consumed 5.35 seconds for 16.81 seconds of audio, versus Parakeet's 6.44 seconds. A separate 3.44-second recording produced the correct sentence with 5 live updates and 1.12 seconds of inference. Updates arrive by 560 ms audio chunks, not necessarily word by word; this is not a guaranteed word-end latency. The model is warmed before microphone capture and retained for pause/resume. These synthetic recording checks do not establish user-voice accuracy or perfect recognition.

The packaged Nemotron build was reopened with seven boxes and the existing text size. Native microphone startup reached Listening, and pause/resume returned immediately to Listening with the cached model. The screenshot recovery is tested against its exact transcript; live recognition of the user's voice remains a separate check.
