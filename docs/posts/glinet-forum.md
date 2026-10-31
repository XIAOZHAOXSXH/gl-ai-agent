# GL-AI Assistant — configure your router in plain language (open source, community project)

Hi all, this is a small side project I have been working on for the last weeks and I would like to share it here.

GL.iNet routers can do a lot, but reaching a setting usually means walking down several nested pages: wireless → 5G →
password → save. I wanted to be able to just say what I want. So I built **GL-AI助手 (GL-AI Assistant)**: it adds an
assistant page to the *stock* admin panel, and the model configures the router through GL's own RPC layer, with a
confirmation step before anything is written.

It is open source (MIT), and it is a community project — **not** affiliated with GL.iNet.

![The entry appears in the native sidebar](images/01-menu.png)
*The menu entry sits in the native "System" group. Everything around it — layout, theme, breadcrumb — is untouched.*

## What it does

You type a request in natural language; the model turns it into a single tool call, the router validates the
arguments, and the change is applied through the router's own RPC/ubus interface:

- "change the 5G password to abc12345"
- "who is using my network?"
- "move 2.4G to the least crowded channel"
- "limit the guest network to 5 Mbps"
- "why is the WAN down, check it for me"

![Chat page](images/02-chat.png)

## Why it is not just another embedded page

This was the part I cared about most:

1. **Native menu** — it registers through `/usr/share/oui/menu.d/*.json`, so it behaves like a stock entry
   (same icon slot, highlight, collapse behaviour).
2. **Native look** — colours come only from the SDK4 design tokens (`--primary`, `--background-card`,
   `--divider`, …), so switching between the default / dark / classic themes just works, with no per-theme code.
3. **Native i18n** — strings live in `/www/i18n/`, following the admin language (zh-cn, zh-tw, en, de, es, it, ja).
4. **No system changes** — the package adds **no nginx configuration**, no location, no new service and no restart.
   Installation ends with a config-checked graceful reload so the SDK4 front end picks up the new menu and i18n
   files. Uninstalling removes the single injected `<script>` tag and the admin panel is exactly as it was.

![Dark theme](images/06-dark.png)

## The safety model

Letting a language model touch router configuration sounds risky, so the design assumes the model will occasionally
be wrong:

- **The model has no shell.** It cannot run commands or read files. It can only pick one of 15 registered tools, and
  the Lua side re-validates type, enum, range and risk level afterwards.
- **Every write goes through a confirmation card.** The card shows the tool, the exact arguments and the expected
  impact ("clients on that band will briefly disconnect"), with a countdown. Nothing is executed until you press
  Apply; when the countdown expires the request is cancelled.
- **Declining really means nothing happens.** I verified this on the device: with the card below left alone, the
  countdown expired and `uci show wireless` contained no trace of the new password.
- **Three permission levels:** read-only / ask (default) / automatic. Even in automatic mode, high-risk changes
  (passwords, LAN address, remote access, port forwarding, reboot, anything that widens WAN exposure) still require
  confirmation.
- **Every step is visible afterwards.** Each tool call (name, arguments, result) stays in the conversation as a step,
  so you can go back and see exactly what was read or written instead of trusting a summary.
- **Failures are reported as failures**, not glossed over as "done".

![Confirmation card](images/03-confirm.png)
*Asking for a password change: it first reads the WiFi config (green, read-only), then stops at the confirmation card.*

## Markdown replies

Tool output and model answers are rendered as Markdown — tables and inline code make long status reports readable.

![Markdown rendering](images/04-markdown.png)

## How it is built (short version)

- The admin panel is a Vue 2 runtime-only SPA; a view is loaded with
  `component = eval(await axios.get('/views/gl-sdk4-ui-<view>.common.js'))`, so the bundle's eval result has to *be*
  the component object (a webpack `library` wrapper returns a Module and mounts as an empty page — learned the hard
  way).
- The backend runs inside nginx Lua instead of a separate daemon, to stay light on router hardware. The RPC object
  exposes a single, never-changing `rpc` method that dispatches internally, because `oui.rpc` caches an object's
  method table per worker — adding methods the obvious way would need an nginx restart on every upgrade.
- The agent loop is cooperative stepping (the browser advances one bounded unit per poll). `ngx.timer` is not usable
  (subrequests are disabled in timer context, which breaks `clients.get_list`), and Lua 5.1 cannot yield across
  `pcall`.
- One tool registry is the single source of truth: it drives the model-facing schema, the RPC mapping, the UI steps
  and the confirmation policy.

## Compatibility

| Platform | Package | Status |
|---|---|---|
| GL firmware 4.11.0 (GL-MT3000) | `.ipk` | tested on device |
| GL firmware 4.10.1 (GL-MG1300) | `.ipk` | tested on device |
| OpenWrt 21.02 / 22.03 | `.ipk` | package structure verified |
| OpenWrt 24.10+ / 25.x | `.apk` (APKv3) | built with apk-tools v3 in CI, install verified |

The package is about 75 KB compressed (~230 KB installed) and adds no resident process. Capabilities differ per model (MODE button, number of
ports, guest network); the tools probe hardware features first and say so when something is unsupported rather than
pretending to succeed.

## Install

Download from Releases (both formats are published together on every build):

<https://github.com/XIAOZHAOXSXH/gl-ai-agent/releases>

**GL firmware 4.x / OpenWrt 21–22 (opkg)**

```sh
opkg install gl-ai-agent_0.1.0_all.ipk
```

**OpenWrt 24.10+ / 25.x (apk)**

```sh
apk add --allow-untrusted gl-ai-agent-0.1.0-r1.apk
```

Then open **System → GL-AI助手** and fill in your model API from the gear icon:

![Settings](images/05-settings.png)

- Protocols: **OpenAI-compatible / Anthropic / Gemini**, with a custom `base_url` (works with relays and self-hosted
  gateways)
- Optional HTTP proxy for the model endpoint
- TLS verification can be turned off for networks that intercept it with their own certificate (on by default; your
  call)
- The model **must support function calling** — plain chat models cannot drive the tools

## Limitations and roadmap

- Version **0.1.0**, early stage.
- Experience depends heavily on the model; a model with solid tool calling is the difference between one clean step
  and going in circles.
- Session history UI is not built yet (the backend API exists).
- Some areas are incomplete: port forwarding can only add rules (no list/edit/delete yet); DDNS and parental controls are not covered.
- Only tested on the two devices above — more models and firmware versions welcome.

Planned: session history, more tools, and context trimming for 128 MB devices.

## Feedback

If you try it, a report with **model + firmware version + the exact sentence you used + a screenshot** is enough for me
to reproduce almost anything. `logread | grep -i glai` is helpful when an RPC call fails.

Repo: <https://github.com/XIAOZHAOXSXH/gl-ai-agent> (MIT, PRs welcome)

> **Disclaimer:** unofficial community project, not affiliated with or endorsed by GL.iNet. It does change router
> settings, so evaluate the risk yourself. It adds no nginx configuration and no system service, and uninstalling
> restores the admin panel to its original state.
