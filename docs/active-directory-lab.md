# Active Directory lab: MACOS-LAB domain

Adds a Windows Server 2025 domain controller to the Parallels lab and joins the
two Ubuntu k3s nodes to its domain, with DNS designed to degrade gracefully when
the DC is off. Built 2026-07-04.

| Machine | Role | IP | Domain name |
|---------|------|-----|-------------|
| Windows-Server | DC, DNS, forest root | 10.211.55.10 (static) | windows-server.macos-lab.local |
| k8s-cp | domain member | 10.211.55.8 | k8s-cp.macos-lab.local |
| k8s-worker1 | domain member | 10.211.55.9 | k8s-worker1.macos-lab.local |

- Forest / domain: `macos-lab.local` (a proper dotted zone — a single-label
  `MACOS-LAB` domain breaks DNS/Kerberos, so NetBIOS is `MACOS-LAB` but the DNS
  domain is `macos-lab.local`). Log in as `MACOS-LAB\glupa` or `glupa@macos-lab.local`.
- `glupa` is a Domain Admin. DSRM/recovery password is the lab password.

## Getting the OS (Apple Silicon caveat)

Parallels on Apple Silicon runs only ARM64 guests, and Microsoft no longer offers
a public Windows Server ARM64 download. This lab uses the community-preserved
**Windows Server 2025 Insider ARM64** ISO (build 26080) from the Internet Archive
item `arm64windows` (SHA1 `5f913e76be3ee982c42854ee6e300ad96e42c567`, verified
against the archive manifest). Eval build, fine for a NAT-isolated lab; do not use
in production. UUP dump (the usual route) no longer has a working ARM64 server set.

## Windows Server first boot

**Networking needs Parallels Tools first.** The default adapter is VirtIO, which
Windows has no driver for — the VM has no network until you install Parallels
Tools (Actions -> Install Parallels Tools inside the VM), then reboot.

Then, in an elevated PowerShell:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm https://raw.githubusercontent.com/glupa-claude/claude/main/scripts/windows-server-bootstrap.ps1 | iex
```
[`windows-server-bootstrap.ps1`](../scripts/windows-server-bootstrap.ps1): creates
the `glupa` admin user, enables RDP, installs OpenSSH server (PowerShell as default
shell), renames to `Windows-Server`, reboots. After reboot the box is reachable by
key over SSH like the Ubuntu nodes (the VM key was added to
`C:\ProgramData\ssh\administrators_authorized_keys`).

A static IP (10.211.55.10) is set so the DC's own address never moves — do this
before promotion, because domain members hardcode the DC as their DNS server.

## Promoting to a domain controller

[`windows-ad-setup.ps1`](../scripts/windows-ad-setup.ps1) installs AD DS + DNS and
runs `Install-ADDSForest` for `macos-lab.local`. It reboots itself. After reboot:
```powershell
Add-ADGroupMember -Identity "Domain Admins" -Members glupa
Set-DnsServerForwarder -IPAddress 10.211.55.1   # forward internet names to Parallels
```
The forwarder is what lets domain-joined machines resolve internet names through
the DC while it is up.

## Joining the Ubuntu nodes

Per node: `sudo DC_IP=10.211.55.10 bash scripts/ubuntu-domain-join.sh`
(see [`ubuntu-domain-join.sh`](../scripts/ubuntu-domain-join.sh)). Two non-obvious
things that this script bakes in, both learned the hard way:

1. **Join via Samba, not adcli.** Server 2025's KDC rejects the machine-account
   password set that this `adcli` performs over Kerberos, failing with
   `Couldn't set password for computer account: Message stream modified`.
   `realm join --membership-software=samba` (needs `samba-common-bin`) uses
   net-ads and succeeds. If a failed adcli attempt left a stale computer object,
   delete it on the DC first: `Get-ADComputer -Filter "Name -eq 'K8S-CP'" | Remove-ADComputer`.

2. **DNS failover uses `DNS=` with two servers, not `FallbackDNS=`.**
   systemd-resolved's `FallbackDNS=` only applies when no `DNS=` is configured at
   all — it is *not* a failover. To keep internet resolution working with the DC
   off, list both under `DNS=`: `DNS=10.211.55.10 10.211.55.1`. resolved uses the
   DC first and rotates to the Parallels DNS when the DC stops answering.

### The local-vs-AD `glupa` collision (intentional)

Each Ubuntu node still has its original **local** `glupa` (uid 1000) whose
`~/.ssh/authorized_keys` holds our lab key — that is how passwordless SSH admin
works, so it is kept on purpose. With `use_fully_qualified_names = False`, plain
`glupa` therefore resolves to the *local* user; the *AD* identity is
`glupa@macos-lab.local` (uid 1459001000). Use the FQ name for anything that must
be the domain account (e.g. `kinit glupa@MACOS-LAB.LOCAL`).

## Verified behavior (2026-07-04)

- `kinit glupa@MACOS-LAB.LOCAL` issues a TGT; `id glupa@macos-lab.local` shows the
  `domain admins` group.
- Forward + reverse DNS resolve all three machines by name in both directions.
- **DC-off test:** stopping the DNS service on the DC, both Ubuntu nodes still
  resolved `github.com` / `ubuntu.com` via 10.211.55.1 — internet DNS survives the
  DC being down, as required. (AD names stop resolving then, which is expected.)

## DNS records for the Ubuntu nodes

Their A/PTR records were added on the DC explicitly (IPs are DHCP leases, so if a
node's lease changes, re-run the `Add-DnsServerResourceRecordA` line for it):
```powershell
Add-DnsServerResourceRecordA -ZoneName macos-lab.local -Name k8s-cp      -IPv4Address 10.211.55.8 -CreatePtr
Add-DnsServerResourceRecordA -ZoneName macos-lab.local -Name k8s-worker1 -IPv4Address 10.211.55.9 -CreatePtr
```
