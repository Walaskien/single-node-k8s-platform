# Provisioning the production node with Ansible

`docs/production-node.md` describes the single-node `kubeadm` cluster this project
targets, by hand. This playbook is that procedure as code: a bare Rocky Linux 10 /
RHEL-family host in, a working cluster out, in one command.

```bash
ansible-galaxy collection install -r requirements.yml
cp inventory.example.ini inventory.ini      # point it at your host
ansible-playbook site.yml
```

## What it does

| Role | Responsibility |
|---|---|
| `prereqs` | swap off, SELinux permissive, `overlay`/`br_netfilter`, sysctls, firewalld (80/443 only) |
| `containerd` | install containerd, default config with `SystemdCgroup = true`, enable |
| `kube_packages` | `pkgs.k8s.io` repo, pinned `kubelet`/`kubeadm`/`kubectl`, held against `dnf update` |
| `control_plane` | `kubeadm init`, kubeconfig for root, remove the control-plane taint, flannel CNI |
| `ingress` | helm, then HAProxy Ingress with `hostNetwork` so the node's own IP is the entrypoint |
| `storage` | local-path provisioner, marked the default StorageClass |
| `cert_manager` | optional (`install_cert_manager: true`) — installs cert-manager; issuers live in `platform/` |

## Design notes

- **Pinned versions.** Every component version lives in `group_vars/all.yml`, pinned to the
  reference node (Kubernetes 1.36, flannel, HAProxy Ingress, local-path). Upgrades are a
  deliberate edit, not drift.
- **Idempotent.** `kubeadm init` is guarded by `creates:`, package and service state is
  declarative, and `kubectl apply` is convergent — a second run changes nothing.
- **Single-node firewall.** Only 80/443 are opened. kubelet, flannel and etcd traffic never
  leaves the host, so the usual inter-node ports stay closed. Set `open_api_port: true` if you
  drive `kubectl` from another machine.

## Verified

`ansible-lint` and `ansible-playbook --syntax-check` run clean. A full end-to-end run needs a
throwaway Rocky 10 VM; nothing here has been run against a live production node.
