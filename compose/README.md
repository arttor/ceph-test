# ceph-test dashboard playground

A `docker compose` stack that runs [ceph-test](../README.md) with the dashboard and metrics fully wired up, so the Ceph dashboard is populated with no manual setup.

Run from this directory:

```bash
docker compose up --build
```

(or from the repo root: `docker compose -f compose/docker-compose.yaml up --build`)

Then open http://localhost:8443 and log in with `admin` / `admin`.

## What it runs

| Service | Port | Purpose |
|---|---|---|
| `ceph` | 8443 (dashboard), 8080 (S3), 9283 (exporter) | ceph-test with dashboard, prometheus module, and test orchestrator enabled |
| `prometheus` | 9090 | scrapes Ceph metrics; loads the Ceph alert rules shipped in the image |
| `alertmanager` | 9093 | receives firing alerts |
| `grafana` | 3000 | pre-provisioned Prometheus datasource + the Ceph dashboards shipped in the image |
| `node-exporter` | 9100 | host CPU/memory/disk metrics |

In the dashboard: cluster health, capacity, and pool/OSD stats show natively; the "Overall Performance" tabs embed Grafana graphs (http://localhost:3000); the Alerts page lists firing Ceph alerts. The Ceph target may show as down in Prometheus for the first 15-30s while the mgr `prometheus` module starts serving.

## Multi-cluster

Add a second cluster to exercise the dashboard's multi-cluster management:

```bash
docker compose --profile multicluster up --build
```

Onboard it in the first dashboard under **Multi-Cluster > Manage Clusters > Connect Cluster**:

- URL: `http://ceph2:8443`
- Username / Password: `admin` / `admin`

`ceph2` gets its own fsid automatically (each container `mkfs`es at startup), so the multi-cluster view treats it as distinct. `CEPH_TEST_ORCHESTRATOR` is on for both — the onboarding flow needs an orchestrator on the hub. `ceph2` is not published to the host; the hub reaches it in-network.

## Stopping

```bash
docker compose down -v
```

`-v` also removes the volumes holding the copied Grafana dashboards and Prometheus rules. Add `--profile multicluster` if you started the second cluster.

## Image

The stack uses `ghcr.io/arttor/ceph-test:v20`. `docker compose ... --build` builds it locally from the repo root (`../Dockerfile`); without `--build` it is pulled from the registry.

## Files

- `docker-compose.yaml` — the stack
- `prometheus.yml` — scrape config + alerting
- `alertmanager.yml` — minimal receiver
- `grafana/provisioning/` — datasource + dashboard providers
