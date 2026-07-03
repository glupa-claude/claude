# webshop — demo app for the Kubernetes lab

A tiny "web shop" (the `traefik/whoami` echo server) used to demonstrate core Kubernetes
behavior on the 2-node lab cluster. Each response includes the pod name, which makes load
balancing and rollouts visible.

Deploy (from the Mac):

```sh
for f in k8s/demo-app/*.yaml; do echo "---"; cat "$f"; done | ssh k8s-cp 'kubectl apply -f -'
```

Hit it through the Traefik ingress (any node IP works):

```sh
curl -H "Host: webshop.lab" http://10.211.55.8/
```

## Experiments run on 2026-07-03 (all repeatable)

| Scenario | Command | What Kubernetes did |
|----------|---------|---------------------|
| Load balancing | repeat the curl above | responses rotate across all pods |
| Self-healing | `kubectl delete pod <one>` | replacement pod Running in ~5 s |
| Traffic spike | `kubectl scale deployment webshop --replicas=6` | 6 pods, spread over both nodes |
| Rolling update | `kubectl set env deployment/webshop WHOAMI_NAME="webshop v2.0"` | old pods replaced in waves; 119/120 in-flight requests succeeded |
| Node failure | `kubectl drain k8s-worker1 --ignore-daemonsets` | all pods rescheduled onto k8s-cp, service stayed up; `kubectl uncordon k8s-worker1` to restore |

Note from the rolling update: exactly one request failed because this demo container
defines no **readiness probe** — the ingress briefly routed to a pod that was already
terminating. In production, always define `readinessProbe` (and handle SIGTERM
gracefully) to make rollouts truly zero-downtime.
