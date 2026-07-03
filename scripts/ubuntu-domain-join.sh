#!/usr/bin/env bash
# Join an Ubuntu machine to the MACOS-LAB Active Directory domain, with DNS
# configured so resolution KEEPS WORKING when the domain controller is off:
# the DC is only one of the nameservers; the Parallels DNS remains as backup.
#
# Usage:  sudo DC_IP=<windows-server-ip> bash ubuntu-domain-join.sh
# Prompts for the password of the domain admin account (glupa).

set -euo pipefail

DC_IP="${DC_IP:?set DC_IP=<domain controller IP>}"
DOMAIN="macos-lab.local"
JOIN_USER="${JOIN_USER:-glupa}"
FALLBACK_DNS="10.211.55.1"   # Parallels gateway — works with the DC off

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq realmd sssd sssd-tools libnss-sss libpam-sss adcli \
    krb5-user packagekit

# --- DNS: DC first (needed for AD SRV records), Parallels DNS as backup.
# Written as a systemd-resolved drop-in so it survives netplan re-applies.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-macos-lab.conf <<EOF
[Resolve]
DNS=${DC_IP}
FallbackDNS=${FALLBACK_DNS}
Domains=${DOMAIN}
EOF
systemctl restart systemd-resolved

# --- discover and join the realm
realm discover "$DOMAIN"
echo "Joining as ${JOIN_USER} — you will be asked for the AD password:"
realm join -U "$JOIN_USER" "$DOMAIN"

# use short usernames (glupa instead of glupa@macos-lab.local) and homedirs
sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
grep -q pam_mkhomedir /etc/pam.d/common-session || \
    echo "session optional pam_mkhomedir.so skel=/etc/skel umask=077" >> /etc/pam.d/common-session
systemctl restart sssd

echo "== joined. verification =="
realm list | sed -n '1,12p'
getent passwd "${JOIN_USER}@${DOMAIN}" || getent passwd "${JOIN_USER}" || true
echo "DNS test (AD SRV record):"
resolvectl query "_ldap._tcp.${DOMAIN}" || true
