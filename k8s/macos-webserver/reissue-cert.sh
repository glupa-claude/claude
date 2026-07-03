#!/usr/bin/env bash
# Issue a browser-legal (<=398 day) TLS cert for macos-webserver, signed by the
# local mkcert CA, and load it into the k3s cluster as the macos-webserver-tls
# secret. Run on the Mac (needs the mkcert CA + kubectl access to k8s-cp).
#
# Why openssl and not `mkcert <names>`: mkcert issues ~2-year certs, and Safari/
# Chrome on macOS reject any server cert valid for more than 398 days even when
# the CA is trusted. So we sign a 397-day leaf with the mkcert CA by hand.

set -euo pipefail

CAROOT="$(mkcert -CAROOT)"
NODE="${NODE:-k8s-cp}"                 # ssh alias of a control-plane node
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

cat > leaf.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = macos-webserver.macos-lab.local
O = macos-lab
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @san
[san]
DNS.1 = macos-webserver.macos-lab.local
DNS.2 = macos-webserver
DNS.3 = localhost
IP.1 = 10.211.55.8
IP.2 = 10.211.55.9
IP.3 = 127.0.0.1
EOF

openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -out tls.csr -config leaf.cnf
openssl x509 -req -in tls.csr -CA "$CAROOT/rootCA.pem" -CAkey "$CAROOT/rootCA-key.pem" \
  -CAcreateserial -out tls.crt -days 397 -sha256 -extfile leaf.cnf -extensions v3

echo "Issued cert valid: $(openssl x509 -in tls.crt -noout -enddate)"

scp -q tls.crt tls.key "${NODE}:/tmp/"
ssh "$NODE" "export KUBECONFIG=\$HOME/.kube/config
  kubectl create secret tls macos-webserver-tls --cert=/tmp/tls.crt --key=/tmp/tls.key \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f /tmp/tls.crt /tmp/tls.key"
echo "Secret macos-webserver-tls updated. Traefik picks it up automatically."
