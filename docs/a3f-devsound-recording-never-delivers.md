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

## Still open: the cat wedges once it actually hears something

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

Also ruled out here: the client negotiating 8 kHz **stereo** capture. Advertising
mono capability makes it negotiate mono, and the wedge is unchanged. (That change
is worth keeping on its own — a handset microphone is one channel, so offering
stereo capture let clients pick a configuration no real device would have given
them.)

Continuing from here means reverse-engineering the game engine: find the call
site that reaches `hle_dispatch_2` in the `0x70C9xxxx` module and work backwards
to the branch that skips it.

## Verification

The Release simulator build passed the default regression suite (12/12: Final
Battle, Calculator, N95 Calculator) and the X7 Angry Birds touch suite (5/5).
Talking Tom launches, runs the full record cycle against the live microphone, and
the log contains no panic, access violation, or unimplemented MMF opcode.
