# The dual-homed node

A single-node cluster that serves real users usually ends up with two network interfaces:
one on the network where the workloads live, one on the network the administrators reach it
from. That second interface is what makes the node useful and what makes its routing
non-obvious.

This document is about a failure that has a memorable shape: **SSH from inside the network
works, the same SSH through a port forward from outside times out.** Nothing is listening
wrong, nothing is firewalled. The cause is that a host with two default gateways answers on
the wrong one.

The commands here are `netplan` and `systemd-networkd`, because the node was Ubuntu. On the
RHEL-family node described in [`production-node.md`](production-node.md) the equivalents are
NetworkManager keyfiles and `nmcli connection modify`; the routing problem and its fix are
identical, only the syntax moves.

## The symptom

```
ens33   192.168.5.224/24    service network,   gateway 192.168.5.2
ens36   192.168.1.224/24    management network, gateway 192.168.1.1
```

A router forwards `203.0.113.10:47852` to `192.168.1.224:22`. From a workstation on
`192.168.1.0/24` the node answers instantly. Through the forward the TCP connection never
completes — not refused, not reset, just silence until the client gives up.

The instinct is to look at `sshd`, then at the firewall, then to blame the router. All three
were fine: `sshd` was bound to `0.0.0.0:22` with no `ListenAddress`, the firewall was
inactive, the forward was correct.

## Finding it

One command settles it, and it is worth knowing because nothing else in the usual toolbox
asks the right question. `ip route get` accepts a source address, which is how you ask the
kernel what a *reply* would do:

```console
# ip route get 8.8.8.8 from 192.168.1.224
8.8.8.8 from 192.168.1.224 via 192.168.5.2 dev ens33
```

A packet whose source is the management address leaves through the *service* interface. The
external client's SYN arrives on `ens36`, `sshd` answers, and the SYN-ACK is routed out
`ens33` to a gateway that has no idea the connection exists. The reply either never reaches
the client or is dropped as martian on the way. From inside `192.168.1.0/24` the reply is a
link-local delivery that never consults the default route at all, which is exactly why local
access keeps working and hides the problem.

The routing table said the same thing less legibly — three default routes, of which only the
lowest metric ever matters:

```
default via 192.168.5.2 dev ens33 metric 101
default via 192.168.6.1 dev ens36 metric 1024   # from a DHCP lease nobody asked for
default via 192.168.1.1 dev ens36 metric 20100
```

## The fix: one routing table per interface

A host with two upstreams needs to route by *source*, not only by destination. Each
interface gets its own table and a rule that sends traffic originating from that
interface's address to it. `netplan` expresses this directly:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: ["192.168.5.224/24"]
      routes:
        - {to: "default", via: "192.168.5.2", metric: 100}
        - {to: "default", via: "192.168.5.2", table: 100}
        - {to: "192.168.5.0/24", scope: "link", table: 100}
      routing-policy:
        - {from: "192.168.5.224", table: 100}
    ens36:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses: ["192.168.1.224/24"]
      routes:
        - {to: "default", via: "192.168.1.1", metric: 200}
        - {to: "default", via: "192.168.1.1", table: 101}
        - {to: "192.168.1.0/24", scope: "link", table: 101}
      routing-policy:
        - {from: "192.168.1.224", table: 101}
```

Each interface declares its default route twice on purpose: once in the main table with a
metric, which decides where *outbound* traffic initiated by the node goes, and once in a
private table, which decides how *replies* from that address get out. The `scope: link`
entry is needed because a private table starts empty — without it the table can route to the
gateway but not to the local subnet.

After applying, the same query answers correctly:

```console
# ip route get 8.8.8.8 from 192.168.1.224
8.8.8.8 from 192.168.1.224 via 192.168.1.1 dev ens36 table 101
```

Two details that matter when you do this on a machine you can only reach remotely:

- **Rules can be added live without dropping sessions.** Adding a rule for
  `192.168.1.224` does not disturb a session established to `192.168.5.224`, so the fix can
  be tested before it is made permanent.
- **`netplan generate` validates without applying.** Writing the file and generating the
  `systemd-networkd` units leaves the running configuration untouched, so a scheduled reboot
  becomes the test rather than a gamble on `netplan apply` over the link being reconfigured.

`rp_filter` deserves a mention because it is the usual suspect and was not the problem here:
it was already `2` (loose mode), which accepts asymmetric returns. Strict mode (`1`) would
have dropped the inbound packets outright and produced the same silence for a different
reason — worth checking, quick to rule out.

## The other half: addresses that did not survive reboot

The same node lost its static addresses on every boot and came up with an extra one from a
DHCP server on a third network. Three configuration sources were fighting:

| Source | What it did |
|---|---|
| `/etc/netplan/00-installer-config.yaml` | static addresses, rendered by `systemd-networkd` |
| `/etc/netplan/90-NM-*.yaml` | the same interfaces again, rendered by NetworkManager |
| `/run/systemd/network/zzzz-dracut-default.network` | `Match: Kind=!*` with `DHCP=yes` |

Both NetworkManager and `systemd-networkd` were enabled, so each boot was a race for the
same interfaces, and whichever finished last won. The third file is the one that surprises
people: it ships in the initramfs, matches *every* non-virtual interface, and turns on DHCP
for anything the other configs do not explicitly claim.

The resolution is to have exactly one renderer and exactly one file:

```console
# one netplan file, one renderer
rm /etc/netplan/90-NM-*.yaml
systemctl disable --now NetworkManager && systemctl mask NetworkManager
systemctl enable systemd-networkd

# neutralise the initramfs DHCP default: /etc overrides /run for the same unit name
ln -sf /dev/null /etc/systemd/network/zzzz-dracut-default.network
```

Masking rather than merely disabling NetworkManager matters, because a package upgrade will
re-enable a service that was only disabled. The `/dev/null` symlink is the standard way to
suppress a `systemd` unit file you do not own — `/etc/systemd/network` takes precedence over
`/run/systemd/network` for a file of the same name, so the DHCP default is overridden
without touching the initramfs.

Setting `dhcp4: false` alone would not have been enough. It governs interfaces netplan
manages; the dracut default is what claims the ones it does not.

## Why this belongs in a single-node design

Multi-node clusters hide this class of problem behind load balancers and health checks: a
node that answers on the wrong interface is drained and the failure reads as capacity loss.
With one node there is nothing to drain, and the same fault presents as "the service is
down for everyone outside the office" — which is why the network configuration of that one
node deserves to be written down and version-controlled rather than discovered twice.

It is also a reminder of where a single-node deployment's real risk lives. Node loss is the
obvious one and it is well understood. The likelier incident is a routine reboot that brings
the node back with a different network identity, at which point cluster certificates bound
to the old address stop matching and the control plane argues with itself. Pinning the
addresses is what keeps a reboot boring.
