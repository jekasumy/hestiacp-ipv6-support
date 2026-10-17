# IPv6 support for Hestia Control Panel (unofficial patch)

This repository adds full IPv6 support to [Hestia Control Panel](https://hestiacp.com):
websites, webmail, DNS zones, mail, FTP and the firewall. It installs on top
of an existing Hestia server and can be removed again.

> [!WARNING]
> **This is an unofficial, community patch. It is not made, reviewed or
> supported by the HestiaCP team.**
>
> It replaces core Hestia files and changes the configuration of nginx/Apache,
> Exim, vsftpd, the firewall and the network configuration of your server. A
> mistake, an unusual setup or an incompatible Hestia version can make
> websites, mail or the whole server unreachable.
>
> **Use it at your own risk.** The software is provided "as is", without
> warranty of any kind (see [Disclaimer](#disclaimer)). The author(s) are not
> responsible for any damage, data loss, downtime, rejected mail or other
> consequences of using it. Always try it on a test server first and keep a
> full backup of production servers.

---

## Contents

- [What it does](#what-it-does)
- [Requirements and compatibility](#requirements-and-compatibility)
- [Before you install](#before-you-install)
- [Install](#install)
- [Using IPv6 in Hestia](#using-ipv6-in-hestia)
- [Command line](#command-line)
- [Uninstall](#uninstall)
- [Upgrading Hestia](#upgrading-hestia)
- [Known limitations](#known-limitations)
- [Repository layout](#repository-layout)
- [Disclaimer](#disclaimer)
- [License](#license)

## What it does

**IP addresses**
- Each system IPv4 address can be paired with an IPv6 address (*Server → IP*
  → Add/Edit IP, or the command line).
- An IPv6 address already configured on the network interface (by your
  provider, SLAAC/DHCPv6 or by hand) is detected and paired automatically
  when an IP is added.
- An address entered with a prefix (e.g. `2001:db8::10/64`) is added to the
  interface and saved to netplan / `/etc/network/interfaces`, and removed again
  when the IP is deleted.
- The same IPv6 address can't be paired with two IPs; link-local, loopback,
  multicast and IPv4-mapped addresses are rejected.

**Websites (nginx and Apache)**
- The *IP Address* field on the Add/Edit Web Domain page is one dropdown with
  the IPv4 addresses (pick one) and every IPv6 address paired with the user's
  IPs (tick any number).
- By default a site listens on the IPv6 address paired with its IPv4.
  Unticking all IPv6 addresses makes it IPv4-only.
- Works with every stock web template (nginx, nginx + Apache, Apache), SSL,
  HTTP/2, and the per-IP default ("catch-all") vhosts.
- Users can only pick IPv6 addresses of IPs they are allowed to use.

**Webmail**
- Listens on the same IPv6 addresses as the website of the same domain.

**DNS**
- Zone templates get AAAA records for the IPv6 addresses (one record per
  address) and an `ip6:` mechanism in the SPF record next to `ip4:`.
- The same combined *IP Address* dropdown on the Add/Edit DNS Zone pages; a
  website's IPv6 choice is applied to its own DNS zone.
- Changing a zone's IP, an IP's IPv6 pairing or restoring a backup keeps AAAA
  records and SPF in sync. AAAA records you added by hand (e.g. pointing at a
  CDN) are never touched.

**Mail (Exim)**
- Mail is accepted over IPv6.
- Mail is sent over IPv6 to receivers that support it, from the mail domain's
  IPv6 address (the same way Hestia sends from the domain's IPv4 address).

**FTP**
- vsftpd and ProFTPD listen on IPv6 (vsftpd falls back to IPv4 only on
  kernels with IPv6 disabled).

**Firewall and fail2ban**
- The Hestia firewall builds an `ip6tables` ruleset next to the `iptables`
  one: rules open to everyone (`0.0.0.0/0`) apply to IPv6 too.
- Firewall rules can target an IPv6 address or network directly.
- IPv6 IPset lists are applied to `ip6tables`.
- ICMPv6 neighbour discovery, router advertisements, path MTU discovery and
  DHCPv6 are always allowed, so IPv6 keeps working whatever rules you add.
- fail2ban can ban IPv6 addresses; bans can be listed and removed in the
  panel.

**Panel**
- All new interface strings are translatable; Russian and Ukrainian
  translations are included (English is the source language).

## Requirements and compatibility

- Hestia Control Panel **1.10.x** on Debian or Ubuntu, installed with the
  standard installer.
- The patched files are complete copies of Hestia files taken from the
  upstream `main` branch (commit `4a8cfc3`, version 1.10.5 era). Installing
  them on another Hestia version also replaces those files with this
  version's, so other differences between the versions come along. Check your
  version with `grep VERSION /usr/local/hestia/conf/hestia.conf` and test
  first.
- The server needs working IPv6 connectivity from its provider for any of this
  to be reachable from the internet.

## Before you install

1. **Make a full backup** of the server (provider snapshot if possible).
2. **Try it on a test server** with the same OS and Hestia version first.
3. Make sure IPv6 works on the server: `ip -6 addr` shows a global address and
   `ping -6 google.com` works.
4. For outgoing mail over IPv6, ask your provider to set a **PTR (reverse
   DNS) record for the IPv6 address** pointing at your mail hostname, and add
   the matching AAAA record. Without it, large providers (Gmail, Outlook, …)
   reject mail sent over IPv6 — Exim does not fall back to IPv4 after such a
   rejection, so the mail bounces.

## Install

As root:

```bash
git clone https://github.com/jekasumy/hestiacp-ipv6-support.git hestiacp-ipv6-support
cd hestiacp-ipv6
./install-ipv6-patch.sh
```

The installer:

1. **Backs up** every Hestia file it is about to replace to
   `/root/hst_backups/ipv6-patch-<date>/` and records which files are new.
2. **Copies** the files from `bin/`, `func/`, `install/` and `web/` into
   `/usr/local/hestia` (same paths).
3. **Applies the change to the running server**:
   - refreshes the web, mail and DNS templates;
   - rebuilds all users' web, mail and DNS domains;
   - regenerates the per-IP default vhosts;
   - enables IPv6 in Exim and vsftpd;
   - restarts the web, proxy, DNS and mail services;
   - reloads the firewall.

The full output of step 3 is written to
`/root/hst_backups/ipv6-patch-<date>/install-<date>.log`.

Running the installer again (e.g. for a newer version of this patch) is safe:
the backup of your **original** files is kept, so uninstalling always returns
to stock Hestia. If Hestia itself was upgraded in between, the upgraded files
become the new originals.

After installing, pair IPv6 addresses with your IPs (next section). Pairing
updates the default vhost, websites, webmail and DNS zones on that IP
automatically.

## Using IPv6 in Hestia

1. **Pair an IPv6 address with an IP**: *Server → IP → Edit* and enter the
   address in *Paired IPv6 Address*.
   - Without a prefix (`2001:db8::10`): the address must already be configured
     on the server; it is only paired.
   - With a prefix (`2001:db8::10/64`), only when adding a new IP: the address
     is added to the network interface and saved permanently.
2. **Websites**: open *Edit Web Domain*, click the *IP Address* field and tick
   the IPv6 addresses the site should listen on. New domains get the IPv6
   address of their IP by default.
3. **DNS zones**: same *IP Address* field on *Add/Edit DNS Zone*. Zones on an
   IP get their AAAA records and SPF `ip6:` when an IPv6 address is paired
   with that IP.
4. **Firewall**: enter an IPv6 address or network (e.g. `2001:db8::/32`) in
   the IP field of a rule. Rules for `0.0.0.0/0` already cover IPv6.

To check from outside: `curl -6 -I https://your-domain` and
`dig AAAA your-domain`.

## Command line

New commands:

| Command | Description |
|---|---|
| `v-change-sys-ip-ipv6 IP [IPV6\|auto]` | Pair an IPv6 address with a system IP (`auto` = detect from the interface, empty = unpair). |
| `v-change-web-domain-ipv6 USER DOMAIN IPV6 [RESTART]` | IPv6 addresses a website listens on. |
| `v-change-dns-domain-ipv6 USER DOMAIN IPV6 [RESTART]` | IPv6 addresses a DNS zone publishes (AAAA + SPF). |

For the last two, `IPV6` is one of:
- `''` — the default: the IPv6 address paired with the domain's IP;
- `no` — IPv4 only;
- a comma-separated list, e.g. `2001:db8::10,2001:db8::20`.

Commands with a new optional last argument:

- `v-add-sys-ip IP NETMASK [INTERFACE] [USER] [IP_STATUS] [IP_NAME] [NAT_IP] [IPV6_CIDR]`
  — `IPV6_CIDR` empty = auto-detect, `none` = no IPv6.
- `v-add-web-domain USER DOMAIN [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS] [IPV6]`
- `v-add-dns-domain USER DOMAIN IP [NS1] … [NS8] [RESTART] [DNSSEC] [IPV6]`

Firewall rule and ban commands (`v-add-firewall-rule`, `v-add-firewall-ban`, …)
accept IPv6 addresses/networks.

## Uninstall

As root, from the same directory:

```bash
./uninstall-ipv6-patch.sh
```

It restores every original file from the backup, removes the files the patch
added, rebuilds all domains and default vhosts with the original templates,
removes the IPv6 firewall ruleset and switches Exim back to IPv4 only.

Not undone automatically:
- IPv6 addresses the patch added to the network interface stay configured.
- `IP6=`/`IPV6=` values in Hestia's data files stay; stock Hestia ignores
  them.
- AAAA records already in DNS zones stay.
- vsftpd keeps listening on IPv6, which is harmless.

## Upgrading Hestia

> [!IMPORTANT]
> **Run `./uninstall-ipv6-patch.sh` before upgrading Hestia** (`apt upgrade`)
> to an official release, then install the patch again afterwards if it is
> still compatible.

The patched templates contain an IPv6 placeholder that official Hestia does
not fill in. An official upgrade that rebuilds domains while the patch is
installed would produce broken web server configs.

## Known limitations

- If no IP has an IPv6 address paired, websites still listen on all IPv6
  addresses (`[::]`), but there is no default vhost for unknown hostnames on
  IPv6. Such requests go to the first site nginx loads.
- fail2ban bans single IPv6 addresses, not whole /64 networks.
- AAAA records of a suspended DNS zone are not updated while it is suspended.
- There is no switch to keep outgoing mail on IPv4: once installed, Exim sends
  over IPv6 to every receiver that has IPv6 (from the mail domain's IPv6
  address). Set up the PTR record before installing.
- Exim, nginx and Apache configuration was tested with their test commands and
  on a test server, not on every OS/version combination.

## Repository layout

```
install-ipv6-patch.sh     installer (run as root)
uninstall-ipv6-patch.sh   uninstaller (run as root)
bin/  func/  install/  web/
                          the patched Hestia files, in the same layout as
                          /usr/local/hestia - only these four folders are
                          copied to the server
LICENSE                   GNU GPL v3
```

## Disclaimer

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

This includes, without limitation, loss of data, service outages, security
incidents, mail delivery problems, and any costs resulting from them. You are
solely responsible for testing this patch, backing up your servers and
deciding whether it is suitable for your environment.

This project is not affiliated with, endorsed by or supported by the Hestia
Control Panel project. "Hestia" and "HestiaCP" are names of their respective
owners. Please do not report problems caused by this patch to the official
Hestia support channels — open an issue in this repository instead.

## License

Hestia Control Panel is licensed under the GNU General Public License v3, and
so is this patch, which is a modified version of Hestia's files. See
[LICENSE](LICENSE).
