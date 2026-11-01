# Invalid GC activation guest regression

Build this small ARM application with symbian-platform 0.3.0's SDK CMake
toolchain, package the generated `e32/ngage_invalid_gc.exe`, and run it on an
EKA2L1 ROM profile. The application deliberately activates a graphics context
on an unconstructed window.

Expected: the guest client terminates with category `WSERV`, reason 6
(`EWservPanicWindow`), and the emulator remains usable. Before the fix the host
crashed in `graphic_context::active`.

The contract comes from SymbianSource `oss.FCL.sf.os.graphics`:
`windowing/windowserver/nga/SERVER/openwfc/CLIENT.CPP`,
`CWsClient::HandleToClientWindow`, and `gc.cpp`, `CWsGc::Activate`.
`windowing/windowserver/SERVER/w32cmd.h` defines the panic code.
