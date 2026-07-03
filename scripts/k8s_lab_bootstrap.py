#!/usr/bin/env python3
"""Bootstrap a 2-node k3s Kubernetes lab over SSH.

Points at two fresh Ubuntu Server machines and reproduces the lab from
docs/kubernetes-lab-setup.md: installs the SSH key (asking for the password
once if key auth isn't set up yet), hardens sshd to key-only auth, updates
packages, sets hostnames, installs the k3s control plane on the first
machine, joins the second as a worker, and verifies both nodes are Ready.

Requirements on the machine you run this from (Windows/macOS/Linux):
    python 3.9+ and:  pip install paramiko
    the private key file (copy ~/.ssh/id_ed25519_vm from the Mac — it is
    intentionally NOT in the git repo; only the .pub half is).

Usage: edit the CONFIG block below, then:  python k8s_lab_bootstrap.py
Safe to re-run — every step skips itself if already done.
"""

import getpass
import shlex
import sys
import time
from pathlib import Path

try:
    import paramiko
except ImportError:
    sys.exit("paramiko is missing — run: pip install paramiko")

# ======================= CONFIG — EDIT ME =======================
CP_IP = "192.168.1.10"          # control-plane machine
WORKER_IP = "192.168.1.11"      # worker machine
SSH_USER = "glupa"
SSH_KEY_PATH = Path.home() / ".ssh" / "id_ed25519_vm"
CP_HOSTNAME = "k8s-cp"
WORKER_HOSTNAME = "k8s-worker1"
HARDEN_SSH = True               # disable SSH password login once the key works
RUN_APT_UPGRADE = True
# ================================================================

SSHD_HARDENING = """\
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
"""


def log(msg):
    print(f"  {msg}", flush=True)


class Node:
    """One remote machine, driven over SSH with cached sudo password."""

    def __init__(self, ip):
        self.ip = ip
        self.password = None
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    def connect(self):
        try:
            self.client.connect(self.ip, username=SSH_USER,
                                key_filename=str(SSH_KEY_PATH), timeout=15)
            log(f"{self.ip}: connected with SSH key")
        except paramiko.AuthenticationException:
            log(f"{self.ip}: key not accepted yet — falling back to password")
            self._ask_password()
            self.client.connect(self.ip, username=SSH_USER,
                                password=self.password, timeout=15)
            self._install_public_key()

    def _ask_password(self):
        if self.password is None:
            self.password = getpass.getpass(
                f"    password for {SSH_USER}@{self.ip}: ")

    def _install_public_key(self):
        pub = (SSH_KEY_PATH.with_suffix(".pub")).read_text().strip()
        self.run(
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
            f"grep -qxF {shlex.quote(pub)} ~/.ssh/authorized_keys 2>/dev/null "
            f"|| echo {shlex.quote(pub)} >> ~/.ssh/authorized_keys && "
            "chmod 600 ~/.ssh/authorized_keys")
        log(f"{self.ip}: public key installed")

    def run(self, cmd, check=True):
        _, stdout, stderr = self.client.exec_command(cmd, timeout=1800)
        out = stdout.read().decode()
        err = stderr.read().decode()
        status = stdout.channel.recv_exit_status()
        if check and status != 0:
            raise RuntimeError(
                f"{self.ip}: command failed ({status}): {cmd}\n{out}{err}")
        return status, out.strip()

    def sudo(self, cmd, check=True):
        self._ask_password()
        full = f"sudo -S -p '' bash -c {shlex.quote(cmd)}"
        _, stdout, stderr = self.client.exec_command(full, timeout=1800)
        stdout.channel.sendall((self.password + "\n").encode())
        out = stdout.read().decode()
        err = stderr.read().decode()
        status = stdout.channel.recv_exit_status()
        if check and status != 0:
            raise RuntimeError(
                f"{self.ip}: sudo command failed ({status}): {cmd}\n{out}{err}")
        return status, out.strip()


def set_hostname(node, hostname):
    _, current = node.run("hostname")
    if current == hostname:
        log(f"{node.ip}: hostname already {hostname}")
        return
    node.sudo(f"hostnamectl set-hostname {hostname} && "
              f"sed -i 's/{current}/{hostname}/g' /etc/hosts")
    log(f"{node.ip}: hostname {current} -> {hostname}")


def harden_ssh(node):
    status, _ = node.run(
        "test -f /etc/ssh/sshd_config.d/00-hardening.conf", check=False)
    if status == 0:
        log(f"{node.ip}: sshd already hardened")
        return
    node.sudo("cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'\n"
              f"{SSHD_HARDENING}EOF\n"
              "sshd -t && systemctl restart ssh")
    log(f"{node.ip}: sshd locked to key-only auth")


def apt_upgrade(node):
    log(f"{node.ip}: updating packages (can take a few minutes)...")
    node.sudo("export DEBIAN_FRONTEND=noninteractive; apt-get update -q && "
              "apt-get dist-upgrade -yq -o Dpkg::Options::=--force-confdef "
              "-o Dpkg::Options::=--force-confold && apt-get autoremove -yq")
    log(f"{node.ip}: packages up to date")


def install_k3s_server(node):
    status, _ = node.run("systemctl is-active --quiet k3s", check=False)
    if status == 0:
        log(f"{node.ip}: k3s server already running")
    else:
        log(f"{node.ip}: installing k3s control plane...")
        node.run("curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh")
        node.sudo("sh /tmp/k3s-install.sh")
    node.sudo("mkdir -p /home/{u}/.kube && "
              "cp /etc/rancher/k3s/k3s.yaml /home/{u}/.kube/config && "
              "chown -R {u}:{u} /home/{u}/.kube && "
              "chmod 600 /home/{u}/.kube/config".format(u=SSH_USER))
    node.run("grep -q KUBECONFIG ~/.bashrc || "
             "echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc")
    _, token = node.sudo("cat /var/lib/rancher/k3s/server/node-token")
    return token


def install_k3s_agent(node, server_ip, token):
    status, _ = node.run("systemctl is-active --quiet k3s-agent", check=False)
    if status == 0:
        log(f"{node.ip}: k3s agent already running")
        return
    log(f"{node.ip}: joining cluster at {server_ip}...")
    node.run("curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh")
    node.sudo(f"K3S_URL=https://{server_ip}:6443 "
              f"K3S_TOKEN={shlex.quote(token)} sh /tmp/k3s-install.sh")


def kubectl(cp, cmd, check=True):
    return cp.run(f"KUBECONFIG=$HOME/.kube/config kubectl {cmd}", check=check)


def wait_for_nodes(cp, expected, timeout=300):
    log(f"waiting for {expected} Ready nodes...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        _, out = kubectl(cp, "get nodes --no-headers", check=False)
        ready = [l for l in out.splitlines() if " Ready" in l]
        if len(ready) >= expected:
            return
        time.sleep(5)
    raise RuntimeError(f"nodes not Ready after {timeout}s:\n{out}")


def main():
    if not SSH_KEY_PATH.exists():
        sys.exit(f"SSH key not found at {SSH_KEY_PATH} — copy id_ed25519_vm "
                 "(and .pub) from the Mac, or adjust SSH_KEY_PATH.")

    print(f"== control plane: {SSH_USER}@{CP_IP} ({CP_HOSTNAME})")
    print(f"== worker:        {SSH_USER}@{WORKER_IP} ({WORKER_HOSTNAME})")

    cp, worker = Node(CP_IP), Node(WORKER_IP)
    for node, hostname in ((cp, CP_HOSTNAME), (worker, WORKER_HOSTNAME)):
        print(f"\n-- preparing {node.ip}")
        node.connect()
        set_hostname(node, hostname)
        if RUN_APT_UPGRADE:
            apt_upgrade(node)
        if HARDEN_SSH:
            harden_ssh(node)

    print(f"\n-- installing Kubernetes (k3s)")
    token = install_k3s_server(cp)
    install_k3s_agent(worker, CP_IP, token)
    wait_for_nodes(cp, expected=2)
    kubectl(cp, f"label node {WORKER_HOSTNAME} "
                "node-role.kubernetes.io/worker=worker --overwrite")

    print("\n== cluster is up ==")
    _, out = kubectl(cp, "get nodes -o wide")
    print(out)
    print(f"\nNext: ssh {SSH_USER}@{CP_IP} and try kubectl get pods -A,\n"
          "or deploy the demo app from k8s/demo-app/ (see its README).")


if __name__ == "__main__":
    main()
