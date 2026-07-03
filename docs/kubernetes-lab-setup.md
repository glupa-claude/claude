# Kubernetes lab on Parallels (Apple Silicon Mac)

How this lab was built on 2026-07-03, and how to rebuild or extend it. The result is a
real 2-node Kubernetes cluster running in two Ubuntu Server VMs:

| Node | Role | IP (DHCP) | VM name in Parallels |
|------|------|-----------|----------------------|
| `k8s-cp` | control plane + worker | 10.211.55.8 | Ubuntu Linux |
| `k8s-worker1` | worker | 10.211.55.9 | k8s-worker1 |

Both are reachable from the Mac by name (`ssh k8s-cp`, `ssh k8s-worker1`) via
`~/.ssh/config`, key-only authentication with `~/.ssh/id_ed25519_vm`.

## 1. The base VM

1. Download the Ubuntu Server ARM64 ISO (Apple Silicon needs `arm64`, not `amd64`):
   <https://cdimage.ubuntu.com/releases/noble/release/> → `ubuntu-24.04.x-live-server-arm64.iso`.
   Verify: `shasum -a 256 -c <(grep <iso-name> SHA256SUMS)`.
2. Open the ISO with Parallels (`open -a "Parallels Desktop" <iso>`) and click through the
   Installation Assistant. 2 CPUs / 4 GB RAM per node is enough for k3s.
3. In the Ubuntu installer: default everything, **tick "Install OpenSSH server"**.
4. Install your SSH key and lock SSH down to keys only:
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_vm -N ""
   ssh-copy-id -i ~/.ssh/id_ed25519_vm.pub glupa@<vm-ip>
   ```
   Then on the VM, create `/etc/ssh/sshd_config.d/00-hardening.conf`
   (the `00-` prefix matters — sshd takes the *first* value it sees, and cloud-init's
   file is `50-`):
   ```
   PubkeyAuthentication yes
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   ChallengeResponseAuthentication no
   PermitRootLogin prohibit-password
   ```
   Validate and apply: `sudo sshd -t && sudo systemctl restart ssh`.
5. Update everything: `sudo apt-get update && sudo apt-get dist-upgrade -y`.

## 2. Cloning the worker (Parallels **Standard** edition workaround)

Standard edition blocks `prlctl create`, `set`, `clone`, `unregister`, `start` — but
**allows** `prlctl list` and `prlctl register`. The clone therefore happens at the
filesystem level:

1. **Prepare identity on the source VM, then power off.** A straight copy would inherit
   the machine-id, and Ubuntu's DHCP client identifies by machine-id — both VMs would
   fight over one IP. Blanking it makes *each* VM regenerate a fresh one on next boot
   (the source VM's IP will change too — expected):
   ```sh
   sudo hostnamectl set-hostname k8s-cp        # meaningful node names
   sudo sed -i 's/<old-hostname>/k8s-cp/g' /etc/hosts
   sudo truncate -s0 /etc/machine-id
   sudo poweroff
   ```
2. **Copy the bundle** on the Mac (APFS copy-on-write → instant, no extra disk):
   ```sh
   cp -c -Rp "~/Parallels/Ubuntu Linux.pvm" ~/Parallels/k8s-worker1.pvm
   prlctl register ~/Parallels/k8s-worker1.pvm --regenerate-src-uuid
   ```
3. **Give the clone its own MAC address and name.** `prlctl set` is Pro-only, but the VM
   config is plain XML. Quit Parallels Desktop first, then edit
   `k8s-worker1.pvm/config.pvs`: change `<MAC>...</MAC>` to a new value (keep the
   `001C42` Parallels prefix) and `<VmName>...</VmName>` to `k8s-worker1`.
4. **Start both** (`prlctl start` is blocked; `open` works):
   ```sh
   open -g "~/Parallels/Ubuntu Linux.pvm" && open -g ~/Parallels/k8s-worker1.pvm
   prlctl list -a -f     # wait for both IPs to appear
   ```
5. **De-duplicate the clone** over SSH (same key works — authorized_keys was cloned):
   ```sh
   sudo hostnamectl set-hostname k8s-worker1
   sudo sed -i 's/k8s-cp/k8s-worker1/g' /etc/hosts
   sudo rm /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart ssh
   ```
6. Add both nodes to `~/.ssh/config` on the Mac for name-based access.

## 3. Installing Kubernetes (k3s)

[k3s](https://k3s.io) is a CNCF-conformant Kubernetes distribution in a single binary —
control plane, kubelet, containerd, DNS, ingress (Traefik) included. Ideal for small VMs.

**Control plane** (on `k8s-cp`):
```sh
curl -sfL https://get.k3s.io | sudo sh -
```

**Worker join** (on `k8s-worker1`); the token lives on the control plane in
`/var/lib/rancher/k3s/server/node-token`:
```sh
curl -sfL https://get.k3s.io | sudo K3S_URL=https://10.211.55.8:6443 K3S_TOKEN=<token> sh -
```

**kubectl without sudo** (on `k8s-cp`):
```sh
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown -R $USER: ~/.kube && chmod 600 ~/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
```

**Verify:**
```sh
kubectl get nodes -o wide      # both nodes Ready
kubectl get pods -A            # coredns, traefik, metrics-server... all Running
kubectl label node k8s-worker1 node-role.kubernetes.io/worker=worker
```

## Adding more workers

Repeat section 2 with a new name (`k8s-worker2`, new MAC) — cloning from the powered-off
worker is fine — then run the worker-join command from section 3 on it. RAM is the limit:
each node uses ~4 GB of the Mac's 18 GB.

## Known limitations / troubleshooting

- **IPs are DHCP leases.** If a node's IP changes after a long shutdown, update
  `~/.ssh/config` on the Mac (find IPs with `prlctl list -a -f`). If the *control plane's*
  IP changes, workers point at a dead `K3S_URL` — fix the IP in
  `/etc/systemd/system/k3s-agent.service.env` on each worker and restart `k3s-agent`.
- **`sshd_config.d` ordering:** hardening files must sort *before* `50-cloud-init.conf`.
- **Parallels Standard CLI:** anything that *modifies* a VM needs the GUI or the
  config.pvs XML edit above; read-only commands (`list`) and `register` work.
- Uninstalling k3s if ever needed: `/usr/local/bin/k3s-uninstall.sh` (server) /
  `k3s-agent-uninstall.sh` (worker).
