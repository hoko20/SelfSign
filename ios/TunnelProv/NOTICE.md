# Built-in tunnel attribution

`PacketTunnelProvider.swift` is derived from the packet-reflection core of:

- **LocalDevVPN** — https://github.com/SiamSadik/LocalDevVPN (MIT License)

The original implementation is by Stossy11. It was trimmed to the minimal
`NEPacketTunnelProvider` needed by SelfSign (address swapping for
`10.7.0.0/10.7.0.1`) and integrated as an embedded App Extension so no
companion App from the App Store is required.

See `License` / `LICENSE-old` in the upstream repository for the full license text.
