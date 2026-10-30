# GL.iNet Router 4.x Device Skill

Use this as a capability and safety contract. The live router state is authoritative;
never infer support from a product name alone.

## Discovery first

Before a change, call `router_overview` or the read-only tools needed to obtain
model, firmware, network mode, Wi-Fi bands, clients, and WAN state. Treat
`hardware_feature` and the presence of SDK RPC objects as capability gates. If a
capability or version is unknown, ask the user to open the native GL page instead
of guessing or sending an untested RPC.

## GL 4.x version boundaries

- Firewall controls described on the legacy firewall page apply to 4.5 and older.
- Port forwarding is a separate feature from 4.6 onward. Check the available RPC
  object before using it; do not assume `firewall.add_port_forward` exists.
- Network port management requires 4.7 and a compatible model/port layout.
- Client naming, type changes, and IP reservation have additional 4.8 bounds.
- The physical toggle button feature requires 4.8+ and a model with a MODE button.
- Guest Wi-Fi is separated from the main network from 4.5; some Wi-Fi-less models
  have no guest network. Some models have only 2.4 GHz or no Wi-Fi at all.
- AP, repeater/WDS, and other network-mode changes can move or disconnect the
  admin address. LAN defaults are commonly 192.168.8.1, but verify the live state.

## Preconditions and interactions

- In repeater mode, channel and bandwidth may be controlled by the upstream AP.
- 160 MHz can force DFS; do not promise a fixed channel without checking the radio.
- Network acceleration can disable client rate/traffic statistics, rate limiting,
  and parental-control behavior on supported models. Check before limiting a client.
- Randomized client MAC addresses can defeat block rules, parental controls, and
  reservations. Explain this when a selected client is not stable.
- DNS encryption, DNS rebinding protection, IPv6 mode, multi-WAN health checks,
  and NAT/ALG settings can change application behavior. State the trade-off.
- Scheduled tasks depend on a correct time zone and do not run while powered off.

## Action contract

For every requested mutation: read the current state, validate model/firmware/RPC
preconditions, describe the exact change and expected reconnection or outage, wait
for the confirmation gate, apply one bounded change, then read back the result.
Never claim success from a missing/empty RPC response. Prefer reversible changes and
report what to undo. Passwords, LAN address/mode, remote management, port/DMZ rules,
firmware/recovery, reboot, and any change that expands WAN exposure are high risk
and require explicit confirmation even in automatic mode.

## Official references

- https://docs.gl-inet.cn/router/4/network-setting/internet/
- https://docs.gl-inet.cn/router/4/network-setting/wireless/
- https://docs.gl-inet.cn/router/4/features/lan_ip/
- https://docs.gl-inet.cn/router/4/features/guest_network/
- https://docs.gl-inet.cn/router/4/features/network_mode/
- https://docs.gl-inet.cn/router/4/features/port_forwarding/
- https://docs.gl-inet.cn/router/4/features/security/
- https://docs.gl-inet.cn/router/4/features/network_port_management/
- https://docs.gl-inet.cn/router/4/interface_guide/network_acceleration/
- https://docs.gl-inet.cn/router/4/resources/specification/
