# SSH keys

- `ubuntu-vm-id_ed25519` / `.pub` — key pair for the Kubernetes lab VMs
  (`glupa@10.211.55.8` / `.9`, key-only auth).

⚠️ The private key is committed here **by explicit owner decision**, for easy transfer to
other workstations. This repo is public, so treat the key as compromised: never reuse it
for anything internet-reachable, and rotate it if the lab VMs are ever exposed beyond the
Mac's private NAT (port forwarding, bridged networking, cloud).

To use it from a fresh checkout: copy both files to `~/.ssh/`, then
`chmod 600 ~/.ssh/ubuntu-vm-id_ed25519` (OpenSSH refuses group/world-readable keys;
`git clone` does not preserve that permission).
