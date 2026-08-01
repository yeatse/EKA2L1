# Talking Tom never hears anything on Symbian^3

Talking Tom on the X7 (rm-707) ignored the microphone completely: the cat played
its tapped-on animations but never reacted to sound. An earlier round of work had
already made the iOS RemoteIO input path capture real audio, so the suspicion was
that the capture itself had regressed.

## Narrowing it down

Instrumenting the MMF DevSound server showed that the guest reached the recording
path and then stopped talking to the server entirely. The A3F opcode sequence was:

```
0 post_open, 4 init3, 11 max_gain, 13 set_gain, 5 capabilities,
42 samples_recorded, 6 config, 7 set_config, 26 record_init   <- last opcode ever
```

Meanwhile the host input stream was running and delivering real samples, but the
driver-level read queue was permanently empty. Nothing was ever handed to the
guest.

Two things were missing, and each alone was fatal:

* `do_submit_buffer_data_receive()` bailed out when `buffer_info_` was empty. That
  is right for the pre-Symbian^3 protocol, where the client posts an asynchronous
  `GetBuffer` request *before* `RecordInit`, and the recorded buffer completes that
  request. Under A3F the client has no outstanding request at all — it waits for a
  `BufferToBeEmptied` event on the message queue. So no host read was ever queued,
  no buffer ever completed, and the event that would start the cycle was never
  sent.
* Even if the event had been sent, `EMMFDevSoundProxyBTBEData` (opcode 56) had no
  handler. Only its playback twin `BTBFData` (55) was dispatched. The client's
  `CMsgQueueHandler::DoBTBECompleteL` calls it synchronously to learn the buffer
  size and to receive the chunk handle, so the guest would have blocked there.

`mmfdevsoundsession.cpp` and `mmfdevsoundcallbackhandler.cpp` in
`SymbianSource/oss.FCL.sf.os.mmaudio` define the contract: on a filled buffer the
server copies the data into the shared chunk and posts a BTBE event; the client
then calls `BufferToBeEmptiedData`, which writes a `TMMFDevSoundProxyHwBuf` into
slot 2 and completes with the chunk handle when `iChunkOp == EOpen`, or with
`KErrNone` otherwise; the client finally calls `RecordData` to ask for the next
buffer.

The fix follows that: for A3F, `record_init` / `record_data` create the chunk and
queue the host read without needing a client request, and the new
`get_recorded_buffer` fills the buffer description and hands over the chunk handle
the first time each chunk is used. The old protocol keeps its original path.

## Why the cat then wedges once it actually hears something: it is too slow

Short version: with the interpreter, the guest cannot decode the "listening"
animation fast enough to finish it inside the listening window, and the
application latches a busy flag that nothing ever clears again. Enabling the
dynarmic JIT (`ios-use-jit`) makes the whole flow work.

With the loop running, Talking Tom stops drawing. It keeps its own timers running
and keeps the record cycle going at exactly real time, but it never calls
`eglSwapBuffers` again and never recovers, so on screen it looks like a hang.

The trigger is the recorded signal level, and only that. Feeding the guest a
steady -44 dBFS tone instead of the microphone let it render for 90 s (250+
swaps). Feeding it a -5 dBFS tone stopped rendering within the first 50 frames. A
staged run — 45 s of digital silence, an 8 s loud tone, then 70 s of digital
silence again — stopped swapping exactly at the tone and never resumed, so the
state is not left when the sound stops.

While wedged the guest is not blocked on the emulator. Its timers keep being
re-armed, and a process-wide IPC trace shows the record cycle
(`BTBEData` / `RecordData`) as the *only* traffic — no Window Server, no font
server, nothing. So the application is sitting in an internal state that our data
puts it into and never leaves.

Ruled out along the way, all with direct measurements:

* The OpenVG coverage-based swap deferral in `egl_swap_buffers_emu`. The wedge
  happens with zero deferrals, and a run with 31 deferrals (quiet audio) never
  wedged.
* Event-rate starvation of the guest's lower-priority active objects: forcing an
  8x larger record buffer (2 events/s instead of 15) changes nothing.
* Message queue overflow and lost `NotifyDataAvailable` wakeups.
* Kernel-lock contention from the audio thread: the completion callback acquires
  the lock successfully on every sample taken.

### What the guest is actually doing

Guest-side instrumentation narrowed this down a lot. Two probes were used: the
dyncom PC histogram switched to two-second windows (each window cleared after
its dump, and its index logged so it interleaves with the audio and swap
counters), and a per-thread histogram of executed system calls taken in
`lib_manager::call_svc`.

The PC histogram makes the transition exact. Up to the window where the loud
burst begins, the hot buckets are all in one module around `0x70C9E000` —
the software renderer. From the next window on, that module disappears entirely
and the top buckets become `0x700046C0`/`0x70004700` in the application's own
image, at ~33% of all guest instructions. Disassembled, that code is a peak
detector: it assembles little-endian 16-bit samples from byte loads, takes the
absolute value, and keeps a running maximum — the game's voice-activity scan
over each recorded buffer. It never stops running.

The guest is not spinning and not blocked. Instruction volume falls from about
5,000,000 PC samples per two-second window while rendering to about 11,000 once
wedged: it is ~99.8% idle. The SVC histogram shows the engine's main loop still
running at full rate in that state — a condition-variable handshake with its
`IdleDetectorThread` about 65 times a second, ~60 timer requests a second,
`User::WaitForAnyRequest` around 95 times a second, and the DevSound record
cycle. Only two threads exist in the process, so there is no hidden audio worker
stuck somewhere.

The single difference between the healthy and wedged histograms is
`hle_dispatch_2`: several hundred per window while rendering, and **exactly zero**
afterwards. That SVC is the graphics dispatch entry, so the application is not
losing its draw calls somewhere in the emulator — it stops issuing them.

So the engine is alive and ticking at frame rate and deliberately draws nothing,
forever, from the moment a loud buffer arrives. Everything it asks the emulator
for, it gets. Whatever gates its draw step is internal state that our recorded
audio puts it into.

### The application's state machine

Dumping every code segment of the process (name, run address, and the relocated
bytes) mapped the hot PCs to modules. The "renderer" at `0x70C9E000` turned out to
be **qjpeg.dll**: Talking Tom's animations are sequences of full-screen JPEG
frames decoded by Qt's image plugin, so "stops rendering" really means "stops
advancing its animation".

Tracing file opens from the process showed exactly that. It plays `blink`, `yawn`,
`sneeze` and friends normally, then on hearing a sound switches to
`AnimationsBK\listen\` — and stops after `cat_listen0005.jpg`. That directory
holds twelve frames.

Guest breakpoints pinned the logic down. `register_breakpoint` with a module name
never resolved for the application's own `.exe`; the `constantaddr` form with the
absolute address works, and the image loads at `0x70000000` every run.

* `0x70004700` computes `level = peak / 32767.0f` over each recorded buffer.
* `0x70005398` is `setCapturing(bool)`. The idle loop calls it with false every
  tick, which also resets the level to zero.
* `0x700014B0` is `startListening()`: sets `listening = 1` **and `busy = 1`**,
  preloads the listen frames, connects the animation timer and starts it at 10 ms.
* `0x70001480` is `stopListening()`, a slot reached through `qt_metacall`: stops
  the animation timer, clears `listening`, calls `setCapturing(false)`, then calls
  `0x70001304`.
* `0x70001304` is "now play back what you said". It returns immediately if
  `listening != 0` **or if `busy != 0`**.
* `busy` is only ever cleared by the animation-finished handler at `0x70000A7A`,
  which also clears `listening` and capture.

So the design assumes the listen animation finishes — and clears `busy` — before
the listening window closes. The trace showed the opposite:

```
startListening t=1388840765
stopListening  t=1388841808          (+1043 ms)
afterListen: listening=0, playing=1  -> returns, playback never starts
```

Only five of twelve frames were decoded in that second, about 200 ms per frame.
`stopListening` stopped the timer mid-animation, so `busy` stayed 1 forever, and
every later attempt fails the same check — which is why the cat holds the pose and
never reacts again.

### Confirmed by making the guest faster

Turning on the dynarmic JIT (`ios-use-jit: true`) and repeating the same injected
burst:

```
startListening t=1389023867
stopListening  t=1389031961          (+8094 ms, the full burst)
afterListen: listening=0, playing=0  -> start playback
listen frames loaded: 11   (was 5)
talk   frames loaded: 45   (was 0)
```

The animation completes, `busy` is cleared, and Tom replays what he heard. So past
the protocol fix above the recording path was never the problem; the title just
needs roughly 2.5x more guest throughput than the interpreter delivers here.

### Where the guest time actually goes

Attributing the PC histogram to code segments, `qjpeg.dll` is **98.4–98.9%** of all
guest instructions in every window where an animation is playing (five separate
two-second windows, 1.7M–5.2M samples each). Everything else — euser, qtgui,
qtcore, the application itself — is under 1% combined.

That makes the JPEG decode by far the highest-leverage thing to accelerate: this
title only needs about 2.5x, and removing that work would leave almost nothing
behind. Note what the mechanisms here can and cannot reach:

* The patch-DLL system (`src/patch/*` plus a `.map`) replaces a target DLL's
  exports **by ordinal**. `qjpeg.dll` exports only the Qt plugin bootstrap
  (`qt_plugin_instance`, `QT_PLUGIN_VERIFICATION_DATA`); the work is inside
  `QJpegHandler::read()`, a C++ virtual, with libjpeg linked in statically. So the
  ordinal route cannot reach the decode — it would mean shipping a whole
  replacement plugin built against the guest's Qt 4.7 ABI.
* `register_breakpoint` supports keying on a code segment hash (as the Warhammer
  40K patches do), which *can* reach libjpeg's internal entry points inside
  `qjpeg.dll`. That is the cheap way to prototype and measure, at the cost of
  depending on one build's function addresses and struct offsets.
* Native S60 titles decode through ICL (`jpegdecoder.dll`) instead, which is a
  documented Symbian API and a much better long-term HLE target — but Qt titles
  like this one never go through it.

## Verification

The Release simulator build passed the default regression suite (12/12: Final
Battle, Calculator, N95 Calculator) and the X7 Angry Birds touch suite (5/5).
Talking Tom launches, runs the full record cycle against the live microphone, and
the log contains no panic, access violation, or unimplemented MMF opcode.
