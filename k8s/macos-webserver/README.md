# macos-webserver — HTTPS site in the k3s cluster

An nginx container running in the k3s cluster, served over HTTPS at
`https://macos-webserver.macos-lab.local` with a browser-trusted certificate.

## How the "secure padlock" works here

These VMs are on a private network with an internal domain, so a public CA
(Let's Encrypt) cannot issue for them. Instead a **local CA** (created by
[mkcert](https://github.com/FiloSottile/mkcert) on the Mac) signs the site
certificate, and that CA is trusted by the Mac's browser. This is the standard
way to get valid TLS for internal names.

- CA lives on the Mac: `~/Library/Application Support/mkcert/` (private key stays
  there — never committed).
- Leaf cert SANs: `macos-webserver.macos-lab.local`, `macos-webserver`,
  `10.211.55.8`, `10.211.55.9`, `localhost`. Valid until Oct 2028.
- In the cluster the cert is a `kubernetes.io/tls` secret `macos-webserver-tls`;
  Traefik serves it for the ingress host. **The key is only in that secret and on
  the Mac — it is not in this repo.**

## Components (all in [deployment.yaml](deployment.yaml))

- `Deployment` — 2 nginx replicas, page from a ConfigMap (`index.html`).
- `Service` — ClusterIP on port 80 (plain HTTP inside the cluster).
- `Ingress` — Traefik terminates TLS with `macos-webserver-tls` and routes the
  host to the service. TLS is handled at the edge, so the container stays simple.

## Deploy / update

```sh
# TLS secret (from the mkcert-issued files) and page ConfigMap:
kubectl create secret tls macos-webserver-tls --cert=macos-webserver.crt --key=macos-webserver.key \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap macos-webserver-site --from-file=index.html \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deployment.yaml
```

To reissue the cert (e.g. new SAN): `mkcert -cert-file macos-webserver.crt
-key-file macos-webserver.key macos-webserver.macos-lab.local <names/IPs...>` on
the Mac, then re-apply the secret.

## Reaching it from the Mac browser

Two one-time Mac-side steps (need your Mac password, so run them yourself):

```sh
mkcert -install                                   # trust the local CA in the keychain
echo "10.211.55.8 macos-webserver.macos-lab.local" | sudo tee -a /etc/hosts
```

Then open <https://macos-webserver.macos-lab.local> — padlock, no warning. The
Ubuntu nodes already resolve the name through the domain controller's DNS, so no
hosts entry is needed there.
