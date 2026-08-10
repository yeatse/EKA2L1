# Proxy-server Bluetooth netplay never worked, and how to run your own matching server

## Symptom

EKA2L1's Bluetooth netplay has three discovery modes: direct IP, LAN broadcast,
and "proxy server", where every emulator keeps a TCP connection to a central
matching server (`btnetplay.12z1.com:27138` by default) that introduces players
to each other. Direct IP and LAN work. Proxy server finds nothing — a guest
Bluetooth device search just times out with an empty list, on every device and
every game.

## Narrowing it down

Standing up a private matching server made the client side easy to observe,
because the server logs exactly what each client says and can be made to answer
with a known-good packet.

The protocol itself is tiny (`btmidman_proxserv_matching.cpp`):

```
client -> server   0x09 <len> <password>   log in / join a room
                   0x04                     list the other players in my room
                   0x0A                     log out
server -> client   0x05 <count> <entry>*
                   entry := 0x01 <ipv4:4> | 0x00 <ipv6:16>   network byte order
```

Two bugs, both on the emulator side:

**Login was never sent.** `send_login()` had exactly one caller: the
`uvw::error_event` handler installed before `connect()`. On the happy path the
connect handler only installed the data callback and started reading, so the
server never learned the client's password and could not put it in a room. The
error-handler call was not a retry either — the first thing `send_login()` does
is replace that handler with one that only logs.

**The player list was parsed from the wrong offset.** `read_and_add_friend()`
takes the packet base pointer and a cursor, advances the cursor past the address
family byte, and then reads the address itself from `buf` — the start of the
packet — instead of `buf + buf_pointer`. Every friend therefore decoded to the
same four bytes: opcode, count, family flag, and the first byte of the real
address. Even with a correct server reply, the emulator went on to send its
name/address queries to a garbage IP.

The cursor was also a plain `char`, which goes negative past 127 bytes — seven
IPv6 entries are enough — and the reply length was never checked against the
entry sizes.

Nothing in the repo's history suggests this path was ever exercised: the file has
not been touched since 2023, and the upstream default host resolves to
Cloudflare's proxy addresses, which do not forward TCP 27138 at all.

## Fix

- `setup_proxy_server_discovery()` sends the login from the `connect_event`
  handler, and the pre-connect error handler just logs.
- `read_and_add_friend()` reads from `buf + buf_pointer`, takes `nread` and
  bounds-checks the entry against it, uses a 64-bit cursor, and zeroes
  `real_addr_` first — `add_friend()` de-duplicates friends with `memcmp` over
  the whole `saddress`, so the uninitialised tail of an IPv6 address made every
  scan add the same peer again.
- `handle_matching_server_msg()` rejects replies shorter than the two byte
  header.

## Running a matching server

The server is a rendezvous point and nothing else: it reports the public address
each client connected from to the other clients that used the same password, and
carries no game traffic. Everything after that — name queries, virtual Bluetooth
address queries, L2CAP/RFCOMM payloads — is direct UDP between the peers, on
harbour port 35689 plus the virtual port range at `btnet-port-offset`. Peers
therefore still need UPnP or manual port forwarding; the server cannot relay for
them.

Two details worth keeping in any reimplementation, both forced by the client:

- Cap replies at 10 entries *and* 127 bytes. Older builds still have the 8-bit
  cursor, and `MAX_INET_DEVICE_AROUND` is 10.
- Never report a peer whose address equals the requester's. Both would want
  harbour port 35689 on the same public address, so they cannot reach each other
  anyway, and a client handed its own address calls itself.

The client prefers the AAAA record — `setup_proxy_server_discovery()` walks the
`getaddrinfo()` results for the first non-`AI_V4MAPPED` `AF_INET6` entry and
never falls back if the connection fails — so a stale AAAA on the server's
hostname breaks discovery for everyone even when the A record is fine.
