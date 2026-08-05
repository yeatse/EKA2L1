# "No Internet access point": the emulated phone was never provisioned

## Symptom

On a Nokia 5320 (rm-409), *Anrufen: The Test* refuses to go online right after its
disclaimer screen:

> No Internet access point. Retry after configuration.

Nothing in the emulator log mentioned the socket server at all — the game gave up long
before it ever tried to open a socket. Other networked apps behave the same way, which
already suggests the problem is not in the game.

## Narrowing it down

The first useful observation was where the log went *quiet*. With the log filter widened
(`Service.CenRep` is `off` in the normal-use preset, which hides all of this), the run
showed the game opening central repository `0xCCCCCC00` and then giving up. That
repository is CommsDat: from Symbian OS 9.1 on, the whole comms database lives in the
central repository keyspace rather than in a DBMS file, at
`C:\Private\10202be9\persists\cccccc00.cre`.

Dumping that repository is worthwhile because its layout explains everything. Every key is
`<TableId><FieldId><RecordId><Attributes>` (see `commsdat.h` in any Symbian SDK:
`KCDMaskShowRecordType = 0x7f800000`, `KCDMaskShowFieldType = 0x007f0000`,
`KCDMaskShowRecordId = 0x0000ff00`). Record `0x00` is the hidden template a table is
cloned from, record `0xFF` describes the table's schema, and field `0x7F` stands for the
record itself — that last one is the key clients enumerate a table by, and it is mirrored
with bit 31 set as the index CommsDat walks.

Grouping the 823 entries in the 5320 ROM's copy by table gives the answer: GlobalSettings,
Location, WAPAccessPoint, DialOutISP, ModemBearer, OutgoingGPRS and friends are all there,
but the **IAP table (`0x02800000`) does not exist at all**, and neither do LANService or
any access-point-bearing record. That is not corruption — it is what a factory handset
looks like. Access points arrive later, from operator settings or from the user; the
emulator has no such step. Cross-checking other ROMs confirmed the reading: the RM-320 and
RM-507 dumps *do* carry an IAP (an "Easy WLAN" record wired to LANService + LANBearer),
and on those devices the same guests find a connection method without any help.

Before writing any C++, the theory was checked by hand-patching the persisted `.cre` with
a Python round-trip encoder: add one IAP record plus an OutgoingGPRS service record cloned
from the ROM template. The game then moved straight past the dialog and started
downloading — proof that CommsDat was the only thing standing in the way, and that the
record shape borrowed from RM-320 is what clients expect.

The next failure was a different one: `Can't find protocol named tcp`. Real ESOCK exposes
each transport of a stack as its own named protocol, and `RSocket::Open(ss, _L("tcp"))`
resolves the name first (`RSocketServ::FindProtocol`) and then opens with the
family/type/protocol triple that lookup returned. The emulator implements the whole INET
stack as one protocol object named `INet`, so no lookup could ever match. Worse, the
description handed back left `iSockType` uninitialised, since that field was commented out.

## Conclusion

Two independent gaps, both upstream of the socket implementation, which was fine all along:

1. **CommsDat has no access point.** `provision_default_access_point()` (new,
   `services/internet/commsdat.cpp`) adds one packet-data IAP the first time repository
   `0xCCCCCC00` is loaded with an empty IAP table. The service record is cloned from the
   ROM's own OutgoingGPRS template so every field a guest may read holds a value that ROM
   considers sane; the bearer is the ROM's existing generic-NIF modem bearer, and the
   network and location links reuse whatever records the ROM already ships (creating a
   network record only when, as on RM-707, there is none). Every record also gets its
   field-`0x7F` key and the bit-31 index mirror, or CommsDat will not enumerate it. ROMs
   that already carry an IAP are left untouched.

2. **Transports have no names.** `protocol::name_bindings()` lets a stack list the names
   it answers to; INET claims `tcp`, `udp`, `icmp` and their v6 forms, each mapping to a
   family/socket-type/protocol triple. `find_protocol_by_name` consults those after the
   stack's own name, and `FindProtocol` now fills the description — including the socket
   type — from the binding that actually matched.

`RConnection::Start`/`Stop` are also answered explicitly now instead of falling through
the "unimplemented opcode" default: sockets are bridged straight to the host, so there is
no interface for the guest to bring up, and reporting success lets clients proceed to the
transfer.

With both in place the guest's HTTP stack loads, resolves the host through the emulator's
resolver and opens real TCP connections — visible on the host as
`EKA2L1 ... TCP ...->...:80 (ESTABLISHED)` sockets owned by the emulator process.

## Worth knowing

- *Anrufen*'s own service has been shut down for years, so the game still ends at "Network
  error, please try again" after a successful exchange with what now answers on that
  domain. Judge the network path by the host-side sockets, not by the game's verdict.
- Opera Mobile and the ROM's own browser both spin at 100% CPU during start-up on this
  build (Opera stalls building `oprfont.cache3`), so neither is usable as a network test
  vehicle right now. That is a separate, non-network problem.
- `RConnection::GetIntSetting`/`GetDesSetting` (opcodes `0x4C`/`0x4F`) still complete with
  `KErrNone` without writing anything back. Nothing observed so far depends on the values,
  but a guest that does will read rubbish.
