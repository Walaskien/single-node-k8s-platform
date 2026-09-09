# Single-node Kubernetes platform

A reproducible single-node Kubernetes environment for internal line-of-business
applications: private PKI, TLS ingress on internal hostnames, a stateful database with
scheduled backups, S3-compatible object storage, and observability.

The deployment it models is **upstream Kubernetes installed with `kubeadm`** on a single
node — containerd, flannel, HAProxy ingress, local storage — not a lightweight
distribution. One node is a capacity decision, not a simplification: it is a complete
control plane, just not a redundant one.

Everything comes up with one command and tears down with another. The point is that a
reviewer can run it, not just read about it.

```console
make up      # create the cluster and deploy the whole platform
make status  # what is running, what URLs exist, when certificates expire
make down    # destroy everything
```

## Why the lab runs k3d and the real thing runs kubeadm

The target is a `kubeadm` cluster on a single node: a full control plane — API server, etcd,
scheduler, controller-manager — with the control-plane taint removed so workloads schedule
on it. The procedure for building that node is in
[`docs/production-node.md`](docs/production-node.md).

This repository provisions **k3d** instead, for one reason: a reviewer should be able to run
it on a laptop in a few minutes without dedicating a machine. `kubeadm` wants a whole host,
swap disabled and kernel modules loaded; k3d wants a container.

That choice changes nothing above the cluster layer. The manifests in `platform/` and
`apps/` are plain Kubernetes objects and apply unchanged to either, and the pod runtime is
containerd in both — Docker in the lab only hosts the container that stands in for the node.
The differences are confined to the ingress controller, the CNI and the storage class, and
are enumerated in `docs/production-node.md`.

## Why single-node

Small internal deployments — a document system, an ERP, an intranet — often serve tens of
users, not thousands. A three-node control plane costs more to run and to reason about
than the availability it buys at that scale, and the failure most likely to hurt is a lost
database, not a lost node.

So this design accepts single-node as a deliberate tradeoff and spends the effort on the
things that actually bite: **backups that are verified**, **certificates that renew
themselves**, and **a documented recovery path**. Those are addressed in
[`docs/runbook.md`](docs/runbook.md).

What this is not: a high-availability production reference. Node loss means downtime, and
[`docs/architecture.md`](docs/architecture.md) is explicit about where that hurts and what
changes when you outgrow it.

## What gets deployed

| Layer | Component | Why |
|---|---|---|
| Cluster | `kubeadm` on a node; k3d in the lab | Full upstream control plane, single node; k3d only so this runs on a laptop |
| Runtime | containerd | Same in both environments — nothing here uses the Docker socket |
| Ingress | Traefik + TLS | One entry point, hostname-based routing |
| PKI | cert-manager, self-signed root CA | Internal hostnames need certificates nobody can buy |
| Database | PostgreSQL (StatefulSet) | Persistent state, the part worth protecting |
| Backups | CronJob → object storage | `pg_dump` on a schedule, with restore documented |
| Object storage | MinIO | S3 API for backups and app uploads, without a cloud account |
| Observability | metrics-server, Grafana | Enough to answer "is it healthy" and "what changed" |
| Demo app | Static frontend + API | Two hostnames, so cross-origin and TLS behave like the real thing |

## Layout

```
cluster/            k3d cluster definition and host port mappings
platform/           everything that supports applications
  cert-manager/       root CA, ClusterIssuer, certificate policy
  ingress/            ingress class, TLS defaults
  postgres/           StatefulSet, service, backup CronJob
  minio/              object storage and bucket bootstrap
  observability/      metrics-server, Grafana
apps/demo/          a sample workload that exercises the platform
docs/               architecture decisions and the operational runbook
```

Platform and applications are separated on purpose. Platform pieces have their own
lifecycle: they are installed once, upgraded rarely, and shared by every application.
Mixing them into application manifests is what makes clusters impossible to rebuild.

## Requirements

- Docker or Colima
- `k3d`, `kubectl`, `helm`
- `make`

```console
brew install k3d kubectl helm colima docker
colima start --cpu 4 --memory 4 --disk 20
```

Four gigabytes is enough for the whole stack — it was developed and tested on an 8 GB
MacBook Air, with the VM given half of that. `make up` takes about five minutes on a cold
cache, most of it pulling images.

## Certificates and trust

The platform issues its own certificates from a self-signed root. Browsers will not trust
that root until you install it:

```console
make trust-ca    # prints the root CA and how to install it per platform
```

Leaf certificates are issued for **365 days**, not the ten years a private CA tempts you
into. Apple's TLS stack rejects any server certificate valid longer than 398 days, which
produces a failure that looks like a trust problem and is not one. That story, and how to
diagnose it, is written up separately in
[apple-tls-398](https://github.com/Walaskien/apple-tls-398).

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — component diagram, data flows, and the
  decisions behind them, including what to change when this outgrows one node
- [`docs/runbook.md`](docs/runbook.md) — backup and restore, certificate rotation,
  common failures and how they present

## License

MIT — see [LICENSE](LICENSE).
