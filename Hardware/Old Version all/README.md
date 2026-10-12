# Hardware layout

- `Collar/A01/collar_A01.cpp`: collar firmware for animal A01.
- `Collar/A02/collar_A02.cpp`: the same supplied collar firmware compiled for A02.
- `Basestation/basestation.cpp`: supplied ESP8266 base-station firmware.

The canonical implementations remain at the repository root as `collar.cpp` and
`Basestation.cpp`; the files above are Arduino entry points so each device can
be opened and compiled independently while sharing the same multihop protocol.

Protocol used by the Flutter app:

- Commands: `LIVE,<animal>,ON|OFF`, `POLL,<animal>`, `FENCE,<animal>,<count>,...`
- Telemetry: `DATA,<animal>,<battery>,<lat>,<lon>,<alt>,<satellites>,<speed>,<movement>`
- Alerts: `ALERT,<animal>,EXIT|RETURN,...`
- Persistent events: `GET_EVENTS`, `EVENT,<id>,...`, `EVENT_ACK,<id>`
