#!/usr/bin/env bash
# Join an Ubuntu machine to the MACOS-LAB Active Directory domain, with DNS
# configured so resolution KEEPS WORKING when the domain controller is off.
#
# Usage:  sudo DC_IP=<windows-server-ip> bash ubuntu-domain-join.sh
# Prompts for the password of the domain admin account (glupa).

set -euo pipefail

DC_IP="${DC_IP:?set DC_IP=<domain controller IP>}"
DOMAIN="macos-lab.local"
JOIN_USER="${JOIN_USER:-glupa}"
BACKUP_DNS="${BACKUP_DNS:-10.211.55.1}"   # Parallels gateway DNS

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# samba-common-bin is required: we join via Samba's net-ads, not adcli (see below).
apt-get install -yq realmd sssd sssd-tools libnss-sss libpam-sss adcli \
    krb5-user packagekit samba-common-bin

# --- DNS: list BOTH servers so resolution survives the DC being off.
# systemd-resolved's FallbackDNS= is NOT a failover (it only applies when no
# DNS= is set at all). Listing both under DNS= makes resolved try the DC first
# and rotate to the Parallels DNS if the DC is unreachable — so internet names
# still resolve with Windows-Server powered down. AD names naturally stop
# resolving then, but those services are down anyway.
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-macos-lab.conf <<EOF
[Resolve]
DNS=${DC_IP} ${BACKUP_DNS}
Domains=${DOMAIN}
EOF
systemctl restart systemd-resolved
sleep 2

# --- join via Samba membership software.
# Windows Server 2025's KDC rejects the way this adcli version sets the machine
# account password over Kerberos ("Message stream modified"); Samba's net-ads
# join uses a different mechanism that succeeds.
realm discover "$DOMAIN"
echo "Joining as ${JOIN_USER} (enter the AD password when prompted)..."
realm join --membership-software=samba -U "$JOIN_USER" "$DOMAIN"

# short usernames (glupa, not glupa@macos-lab.local) and auto-created homedirs
sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
grep -q pam_mkhomedir /etc/pam.d/common-session || \
    echo "session optional pam_mkhomedir.so skel=/etc/skel umask=077" >> /etc/pam.d/common-session
systemctl restart sssd

# Register this host in the DC's DNS so the DC and peers can resolve it by name.
# (The Samba join does not always create the A record; do it explicitly.)
MYIP=$(ip -4 route get "$DC_IP" | grep -oP 'src \K[0-9.]+')
echo "This host is ${MYIP}. If reverse resolution is needed, on the DC run:"
echo "  Add-DnsServerResourceRecordA -ZoneName ${DOMAIN} -Name $(hostname -s) -IPv4Address ${MYIP} -CreatePtr"

echo "== joined. verification =="
realm list | grep -E "domain-name|login-formats|realm-name"
id "${JOIN_USER}@${DOMAIN}" | head -1
