# OpenVPN 3 widget for DankMaterialShell

A DMS bar and Control Center plugin for [openvpn3-linux](https://codeberg.org/OpenVPN/openvpn3-linux).

Tested on Dux Modular Shell (`dux-shell`) v2.1.2. Besides the plugin API (`PluginComponent`, `startupCheck`), the popout reuses the shell's own Control Center components (`CcGroup`, `CcListRow`, `DButton`, `ConfirmModal`) so it looks the same as the built-in VPN popout. Those are internal, so other DMS versions may need small changes.

The built-in DMS VPN widget only manages NetworkManager connections. Profiles that sign in through the browser (OpenVPN web auth / SAML / OAuth, e.g. Google or Entra ID SSO) don't work with `networkmanager-openvpn`. They fail with `AUTH_FAILED` because the plugin never advertises `IV_SSO`. openvpn3-linux supports them, and this widget puts it in your bar.

## Features

- Bar icon showing the connection state (connected / connecting or waiting for sign-in / disconnected), for horizontal and vertical bars
- Popout with the same layout as the built-in DMS VPN popout: an "Active:" status card with Disconnect, and the profile list. Click a profile to connect or disconnect it, and use the delete button (with confirmation) to remove it
- **Import profile** button: pick an `.ovpn` / `.conf` file and it is imported as a persistent profile named after the file. Duplicate names are refused
- Right-click the icon to toggle your default profile
- Control Center tile that toggles the default profile
- Web-auth profiles: openvpn3 opens the sign-in page in your browser. If it can't, the widget opens the URL itself
- Toasts on connect, disconnect and failure (can be turned off)
- Optional label with the connected profile name

## Requirements

- DankMaterialShell with plugin support
- `openvpn3` (openvpn3-linux), with at least one imported profile

### Installing openvpn3

- **Arch / CachyOS**: AUR package `openvpn3` (`paru -S openvpn3`).
  On systems where OpenSSL 4 is the default, openvpn3 27.x fails to build (`invalid conversion from 'const X509_NAME*'`). Build it against the `openssl-3` compat package instead:
  ```sh
  sudo pacman -S --needed openssl-3
  PKG_CONFIG_PATH=/usr/lib/openssl-3/pkgconfig paru -S openvpn3
  ```
- **Fedora / Debian / Ubuntu**: see the [OpenVPN 3 Linux](https://community.openvpn.net/openvpn/wiki/OpenVPN3Linux) repositories.

### Importing a profile

Use the **Import profile** button in the popout, or the CLI:

```sh
openvpn3 config-import --config ~/Downloads/my-vpn.ovpn --name my-vpn --persistent
openvpn3 configs-list
```

Import each profile once. If the same name is imported twice, `openvpn3 session-start --config NAME` fails with *"More than one configuration profile was found with the given name"*. Remove the extra one with `openvpn3 config-remove --path <path from configs-list --verbose>`.

## Installation

```sh
git clone https://github.com/albertofa/openvpn-dms-bar-widget ~/.config/dms/plugins/openvpn3Vpn
dms ipc call plugins enable openvpn3Vpn
```

Then add **OpenVPN 3** to a bar in *Settings → Appearance → DankBar Layout* (or Control Center edit mode for the tile).

## Usage

| Action | Result |
| --- | --- |
| Left-click bar icon | Open the profile list |
| Right-click bar icon | Connect / disconnect the default profile |
| Control Center tile | Connect / disconnect the default profile |

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Default profile | first imported profile | Profile toggled by right-click and the Control Center tile |
| Refresh interval | 5 s | Status polling while idle (1.5 s while connecting) |
| Show label | off | Show the connected profile name next to the icon |
| Notifications | on | Toasts on connect, disconnect and failure |

## How it works

The widget only calls the `openvpn3` CLI. It needs no root and no extra services:

- `openvpn3 configs-list --json` and `openvpn3 sessions-list` for status
- `openvpn3 session-start --config NAME` to connect (in the foreground, so openvpn3 runs the web-auth flow)
- `openvpn3 session-manage --path PATH --disconnect` to disconnect
- `openvpn3 config-import --config FILE --name NAME --persistent` to import

Profiles that ask for a username/password or a challenge response can't be answered from the widget yet. Start those once from a terminal.

## Development

The output parsers live in `Ovpn3.js` and have Node tests:

```sh
node --test tests/
```

After changing QML, reload the plugin with `dms ipc call plugins reload openvpn3Vpn`.

## License

[MIT](LICENSE)
