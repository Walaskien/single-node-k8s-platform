# The production node

This lab runs on k3d so it fits on a laptop. The deployment it models is upstream
Kubernetes installed with `kubeadm` on a single machine. This document records what that
node looks like, and exactly where the two differ.

## What differs

| | Lab (k3d) | Production node (kubeadm) |
|---|---|---|
| Cluster | k3s in Docker | Upstream Kubernetes, `kubeadm init` |
| Host OS | container | Rocky Linux / RHEL family |
| Container runtime | containerd | containerd |
| CNI | flannel (bundled with k3s) | flannel, applied after `kubeadm init` |
| Ingress | Traefik (bundled) | HAProxy Ingress, installed via Helm |
| Storage | k3d local-path | local-path provisioner, installed separately |
| Ports | 8080/8443 on the host | 80/443 directly on the node |

### Docker in the lab is not the pod runtime

Worth stating plainly, because the requirement to install Docker suggests otherwise: k3d
means "k3s in Docker", and Docker's job there is to impersonate a *machine*. It runs one
container that stands in for the node. Inside that container, k3s starts **containerd**, and
pods run on containerd — the same runtime as production.

```
lab          Colima → Docker → node container → k3s → containerd → pods
production                      Rocky Linux    → kubeadm → containerd → pods
```

So Docker exists only at the outermost layer, only on a laptop, and nothing in the cluster
talks to it. `kubectl get nodes -o wide` reports `containerd://…` under CONTAINER-RUNTIME in
both environments. Anything that depended on the Docker socket would work in the lab and
break on the real node; nothing here does.

### What is not portable

Everything in `platform/` and `apps/` moves between the two, with two exceptions worth
knowing about:

- **`ingressClassName`** — `traefik` in the lab, `haproxy` on the node.
- **Traefik `Middleware`** for CORS is Traefik-specific. On HAProxy the same thing is done
  with `ingress.kubernetes.io/cors-*` annotations on the Ingress itself.

Both are one-line changes, and both are the kind of detail that turns a working manifest
into a broken one when moved between clusters — which is the reason to write them down.

## Bringing up the node

A condensed version of the procedure, for reference rather than for copy-paste — versions
move and the upstream documentation is authoritative.

```bash
# Kubernetes needs swap off and bridged traffic visible to iptables
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

modprobe br_netfilter
cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# container runtime
dnf install -y containerd
containerd config default >/etc/containerd/config.toml
# SystemdCgroup must be true, or the kubelet and containerd disagree about
# cgroups and pods fail to start with errors that do not mention cgroups
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# kubeadm, kubelet, kubectl from the upstream repository, then
kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config

# a single-node cluster must tolerate its own control-plane taint,
# or nothing will ever schedule
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

`--pod-network-cidr=10.244.0.0/16` is not optional with flannel: it expects that range by
default, and a mismatch produces a cluster where pods start but cannot reach each other.

## Ingress

```bash
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
helm install haproxy-ingress haproxy-ingress/haproxy-ingress \
  --namespace haproxy-ingress --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.service.type=ClusterIP
```

`hostNetwork=true` is what makes a single node work without a cloud load balancer: the
controller binds 80 and 443 on the node itself. There is no LoadBalancer service to
provision and no external IP to wait for — the node's address *is* the entry point.

## Storage

`kubeadm` ships no default StorageClass, so every PersistentVolumeClaim stays `Pending`
until one exists. This is the most common surprise on a fresh single-node cluster:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

The second command matters as much as the first. A StorageClass that is not marked default
is not used by claims that do not name it, and the symptom is identical to having no
StorageClass at all.

## Operational notes

- **Certificates.** `kubeadm` issues control-plane certificates valid for one year and
  renews them on control-plane upgrade. On a cluster that is not upgraded regularly they
  expire, and the API server stops accepting connections. `kubeadm certs check-expiration`
  is worth a calendar reminder; `kubeadm certs renew all` fixes it.
- **etcd.** On a single node, etcd is on that node. `etcdctl snapshot save` on a schedule,
  stored off the machine, is what makes the cluster rebuildable rather than merely
  restartable.
- **Node pressure.** With one node there is nowhere to evict to. Resource requests on every
  workload are not bureaucracy here — they are what stops one pod from taking the node
  down with it.
