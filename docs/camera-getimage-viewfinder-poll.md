# GetImage is a viewfinder poll, not a photo: Killer Virus stuttered behind a shutter sound

## Symptom

*Attack of the Killer Virus* on the N70 (`nem-4`) crawled on a physical iPhone, and
the phone kept playing the camera shutter sound over and over for as long as the game
was on screen. Android showed the same stutter — a good hint that nothing in the iOS
backend was to blame on its own.

## Narrowing it down

The emulator log stopped at app startup (the game's `.pcm` sound files being opened),
with no camera line anywhere: the EKA1 `CameraServer` HLE had no logging at all, so
the log said nothing about what the game did next. What it did show was the
dependency closure of `killervirus.app` — `cameraserver.dll`, `ecam.dll`, `camext.dll`,
`camservercore.dll`, `jpegdecoder.dll` — i.e. the game is a camera app.

Two things narrowed it from there:

* On an EKA1 device the `ecam` patch DLL never binds. The log is full of
  `Unable to patch export N of ecam_general.dll` (exports 4..25 don't exist in the
  8.1a `ecam.dll`) and `Invalid ordinal 2123/2128/2132 (of 2073) ... from euser.dll`.
  That patch is built against the S60 5th SDK, so on Symbian 8.1a the ECam dispatch
  path is simply not in play. The game's camera traffic goes to the HLE
  `CameraServer` (`src/emu/services/src/camera/camera.cpp`), which is registered for
  EKA1 only.
* That server implements exactly one frame-producing opcode, `GetImage` (4), and it
  served every call with `instance::capture_image()` — a **still photo capture**.

Running the game against the simulator's mock camera made the access pattern obvious:
`Service.Track` logged `Calling service: CameraServer, id: 4` about **15 times a
second**, continuously. `GetImage` is not "take a photo" for this protocol; it is how
an app that predates `CCamera`'s viewfinder API draws a live viewfinder — it polls
frame after frame after frame.

So each displayed frame ran a full host photo pipeline. On iOS that is
`AVCapturePhotoOutput capturePhotoWithSettings:` — which starts the capture session,
captures at the sensor's full photo resolution, produces a JPEG, decodes it,
rescales it to 640x480, converts it, and stops the session again — plus the system
shutter sound, which apps cannot suppress. On Android it is
`ImageCapture.takePicture` followed by a JPEG decode and scale. Fifteen of those per
second explains both the stutter and the machine-gun shutter.

Worth noting as a dead end for anyone chasing this from the log alone: the `ecam`
patch failures look alarming and are real, but they are not this bug. They only mean
the S60v3+ ECam path is inert on EKA1, which is exactly why the `CameraServer` HLE
exists.

## Fix

Serve `GetImage` from the driver's **viewfinder feed** instead of a still capture, and
leave the feed running between requests:

* `camera_session` now owns a `feed_state` shared with the driver callbacks (frames
  keep arriving on a driver thread, so that state has to outlive the session that
  started it). `wants_frame` gates conversion work so the backend does nothing while
  no request is pending; `pending` is only touched under the kernel lock, which the
  frame callback takes anyway to complete the request.
* The feed is (re)started when the size or format changes — `SetImageQuality` swaps
  between 160x120/`EColor4K` and 640x480/`EColor16M` — and when a previous feed
  reported an error, so a dead feed cannot leave a client waiting forever.
* `start_feed()` drops the kernel lock around `receive_viewfinder_feed()` for the same
  reason the old capture path did: a driver that cannot start the feed reports it
  through the same callback, synchronously.
* Both backends deliver the viewfinder at exactly the requested size with FBS-style
  4-byte-aligned scanlines, which is what `epoc::get_byte_width()` computes for the
  target bitmap, so the copy is now a straight `memcpy` and the nearest-neighbour
  rescale only survives as a fallback.
* The resolution-ladder search is gone (the feed is requested at the size we want),
  replaced by a `supported_frame_formats()` check — both backends drop a feed request
  for an unknown format *without* calling back, which would hang the client.

The EKA1 `CameraServer` also had no logging whatsoever; it now traces feed start/stop
and the quality/lighting settings under `Hle.Camera`.

## Result

On the simulator the game runs at a steady 15 FPS with the camera poll rate matching
it exactly — the camera is no longer the limiter, the emulator's render is. The
still-capture path is untouched for the ECam dispatch path, where a guest asking for
a photo really does want one.

One thing this does not address: `orientConnection` forces portrait delivery, so a
640x480 landscape request is served by squashing a 480x640 portrait buffer. That is
pre-existing behaviour shared with the ECam path, and it costs a CGImage rescale per
frame on top of the format conversion.
