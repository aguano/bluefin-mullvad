# bluefin-mullvad

A personal, custom [Bluefin](https://projectbluefin.io) image with the official [Mullvad VPN](https://mullvad.net) app built in – daemon, GUI and kill switch – delivered as a signed [bootc](https://github.com/bootc-dev/bootc) container image.

> This is a personal project. It is not affiliated with Mullvad VPN AB, Project Bluefin or Universal Blue.

## Why this image exists

Bluefin is an image-based ("atomic") system: the OS is delivered as a complete container image, and local package layering with `rpm-ostree` is discouraged – `ujust update` refuses to run while layered packages are present. Mullvad offers no Flatpak, because its daemon needs direct control over the host's network and firewall. Building a custom image is therefore the clean way to get the full Mullvad app, including its kill switch and early-boot network blocking, while keeping Bluefin's zero-maintenance updates.

## What's different from Bluefin

| Area | Change |
|---|---|
| **Base image** | `ghcr.io/projectbluefin/bluefin:stable` (no digest pin, so every build picks up the current stable release) |
| **Added packages** | `mullvad-vpn` from the official Mullvad RPM repository (daemon, CLI and GUI app) |
| **File layout** | The GUI app is moved from `/opt/Mullvad VPN` to `/usr/lib/Mullvad VPN`, because `/opt` points to `/var/opt` on image-based systems and is not part of the image. Paths in the desktop file and systemd units are rewritten accordingly. |
| **Enabled services** | `mullvad-daemon.service` (VPN daemon incl. kill switch) and `mullvad-early-boot-blocking.service` (blocks network traffic during boot until the daemon takes over) |
| **Repositories** | The Mullvad repository is disabled in the final image – updates arrive with new image builds, not via `dnf` |
| **Removed** | Template examples (`tmux`, `podman.socket`) |

All customizations live in [`build_files/build.sh`](build_files/build.sh), which is documented inline. The build checks itself and fails if any `/opt` paths are left over.

## How updates work

1. **Daily build:** GitHub Actions rebuilds the image every day (10:05 UTC) and on every push to `main`. Each build starts from the current Bluefin stable image and installs the current Mullvad release.
2. **Signing:** Every published image is signed with cosign. The public key is [`cosign.pub`](cosign.pub).
3. **On the machine:** Bluefin's regular update mechanism (`uupd` / `ujust update` / `bootc upgrade`) pulls the new image in the background. It becomes active after the next reboot.
4. **Dependencies:** Dependabot keeps the GitHub Actions used in the workflow up to date via pull requests.

## Usage

### Switch an existing Bluefin installation to this image

```bash
sudo bootc switch ghcr.io/aguano/bluefin-mullvad:latest
sudo bootc status        # "Staged image" should show this image
systemctl reboot
```

### Roll back

```bash
sudo bootc rollback      # boots the previous deployment on next reboot
systemctl reboot
```

Alternatively, pick the second entry in the GRUB menu.

### First-time Mullvad setup

If lockdown mode is active before you've logged in, all traffic is blocked and the app cannot reach Mullvad's servers. In that case:

```bash
mullvad lockdown-mode set off   # temporarily, just for the first login
```

Then log in via the GUI app (not via the CLI, to keep the account number out of your shell history), enable **Auto-connect**, connect, and re-enable lockdown mode if you want it.

### Verify

```bash
rpm -q mullvad-vpn                                      # installed version
systemctl status mullvad-daemon mullvad-early-boot-blocking
mullvad status
curl https://am.i.mullvad.net/connected
```

`mullvad-early-boot-blocking` showing `inactive (dead)` with `status=0/SUCCESS` is expected – it only runs briefly during boot.

### Verify the image signature

```bash
cosign verify --key cosign.pub ghcr.io/aguano/bluefin-mullvad:latest
```

## Maintenance notes

- A failed build means no updates until it's fixed – the machine keeps running on its last good image. GitHub sends an email on failed workflow runs.
- Mullvad's settings and login live in `/etc/mullvad-vpn` and survive image updates and switches. Only a full reinstall creates a new Mullvad device.
- If upstream renames or moves the base image, update the `FROM` line in [`Containerfile`](Containerfile).

## Credits

- Built from [ublue-os/image-template](https://github.com/ublue-os/image-template) (Apache-2.0)
- Base image: [Project Bluefin](https://github.com/projectbluefin/bluefin)
- `/opt` relocation approach adapted from the [fedora-sysexts](https://github.com/fedora-sysexts/community) Mullvad sysext
- VPN client: [mullvad/mullvadvpn-app](https://github.com/mullvad/mullvadvpn-app)
