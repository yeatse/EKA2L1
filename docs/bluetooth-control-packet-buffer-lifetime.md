# Bluetooth discovery sends expired control packets

After correcting the N-Gage device-selection response layout, an iPhone Air
still returned to Dragon World's role menu in LAN mode. A fresh host process
could answer 20 consecutive virtual-address queries, but automatic discovery
still failed. Switching the same installed build to Direct IP reached the map,
separating discovery from the guest response ABI.

A small external UDP probe sent four password-matching discovery requests to
the Air. Each request should receive five player-existence replies, all byte
`0x05`. The twenty actual replies contained four `0x05` bytes and sixteen
`0x00` bytes. This happened without a debugger or emulator tracing.

The LAN callback queued five asynchronous sends of the address of a local
`char`. The bundled uvw raw-pointer overload stores that pointer with a no-op
deleter: it does not copy the payload. libuv may send the first datagram
immediately, but queued sends outlive the callback's stack variable. The
broadcast request similarly borrowed a local vector. Query responses and
matching-server control writes had the same local-storage lifetime error.

The fix supplies an owned copy to uvw's `unique_ptr<char[]>` overload, which
retains the packet through completion and releases it on completion or error.
It changes control-packet ownership, not the protocol or guest socket data.
No callback holding an emulator object is needed to free these copies.

A separate Air log contained sustained `-57` receive errors on both discovery
sockets. Restarting the host cleared that error stream but did not fix the
LAN discovery failure above. Socket recovery after such errors remains a
separate question; the packet-lifetime fix does not claim to address it.
