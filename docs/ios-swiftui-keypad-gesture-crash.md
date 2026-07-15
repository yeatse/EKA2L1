# iOS 26 SwiftUI keypad gesture crash

## Symptom

A TestFlight build crashed on the main thread while an emulated application was
running. The failure was an `EXC_BAD_ACCESS` at address `0x3`, about eleven
minutes after launch. There was no guest panic or graphics halt immediately
before the failure.

The report was from build 260753. Its EKA2L1 image UUID
`2AAC4126-91A6-3DAB-B3B1-EA3771E19959` exactly matched the dSYM produced by the
TestFlight workflow for commit `9daa899b9`. There was only one report from this
build to compare.

## Narrowing the failure

Symbolication showed all EKA2L1 worker threads in ordinary states: the CPU
interpreter was in its main loop, graphics was waiting for commands, libuv was
polling, and the timer and thread-pool workers were asleep. The main thread had
only the SwiftUI application entry frame from EKA2L1. Its active stack was:

1. UIKit delivered a touch event through `UIGestureEnvironment`.
2. SwiftUI's `UIKitResponderGestureRecognizer` asked whether it should require
   another recognizer to fail.
3. UIKit compared recognizer containers with
   `_UIGestureRecognizerContainerCompare`.
4. `NSMutableOrderedSet` attempted to send `isEqual:` to the invalid object
   pointer `0x3`.

This rules out a direct guest, renderer, or emulator-service crash. It also
distinguishes the failure from the earlier render-view recognizers: the custom
long-press and pinch recognizers had already been removed before this build.

The remaining recognizer-heavy surface was the SwiftUI virtual keypad. Every
key used `DragGesture(minimumDistance: 0)`, and the d-pad ring used another one.
A classic keypad therefore contributed many sibling SwiftUI recognizers. Each
recognizer's callback immediately changed SwiftUI state to animate its pressed
appearance, causing SwiftUI to update the same responder tree while UIKit was
resolving recognizer relationships. The crash is inside Apple's private
gesture graph, so one report cannot prove the exact internal stale-reference
sequence, but this is the narrowest application-controlled trigger supported by
the stack.

Changing hit testing or suppressing the invalid object at the emulator layer
would only hide the symptom: EKA2L1 never receives control before the crash.

## Fix

The keypad now tracks down, move, up, and cancel directly with a small
`UIViewRepresentable` responder. It preserves the existing behavior:

- keys send one press and one release, including cancellation and removal;
- the d-pad continues changing direction while a finger slides around its
  ring;
- the circular d-pad and OK hit regions remain circular;
- accessibility activation still uses the existing SwiftUI action.

The UIKit responder does not install a `UIGestureRecognizer`, so keypad state
updates no longer cause SwiftUI to rebuild a large recognizer dependency graph.
The render view's native multi-touch path remains unchanged, which is important
for touch guests such as Angry Birds.

The final Release simulator build passed the full Final Battle/Calculator/N95
Calculator regression (11 checks) and the Angry Birds native-touch suite (5
checks). Post-interaction screenshots also confirmed that the transparent UIKit
touch surfaces do not obscure or alter the SwiftUI key caps.
