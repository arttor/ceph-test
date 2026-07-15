# ceph-test

Single-node Ceph cluster (mon + mgr + osd + rgw) in one container, for testing. Based on `quay.io/ceph/ceph`. Multiarch: `linux/amd64` and `linux/arm64`.

## Usage

```bash
docker run -d --name ceph -p 8080:8080 ghcr.io/arttor/ceph-test:v20
```

With an S3 user:

```bash
docker run -d --name ceph \
  -e CEPH_DEMO_ACCESS_KEY=mykey \
  -e CEPH_DEMO_SECRET_KEY=mysecret \
  -p 8080:8080 \
  ghcr.io/arttor/ceph-test:v20
```

Check status: `docker exec ceph ceph -s`

With the dashboard:

```bash
docker run -d --name ceph \
  -e CEPH_DASHBOARD=true \
  -p 8080:8080 -p 8443:8443 \
  ghcr.io/arttor/ceph-test:v20
```

Then open http://localhost:8443 and log in with `admin` / `admin`.

For a full dashboard playground (Prometheus + Grafana + Alertmanager, plus a multi-cluster example), see [`compose/`](compose/).

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MON_IP` | `0.0.0.0` (auto-detect) | Monitor bind address |
| `CEPH_PUBLIC_NETWORK` | `0.0.0.0/0` | Public network CIDR |
| `CEPH_FSID` | (empty) | Use a specific fsid instead of a random one |
| `CEPH_DEMO_UID` | `demo` | S3 user UID (created only if access key is set) |
| `CEPH_DEMO_ACCESS_KEY` | (empty) | S3 access key. If set, creates an RGW user at startup |
| `CEPH_DEMO_SECRET_KEY` | (empty) | S3 secret key |
| `CEPH_EXTRA_CONF` | (empty) | Extra lines appended to `ceph.conf` before daemons start |
| `CEPH_DASHBOARD` | `false` | Enable the Ceph mgr dashboard (plain HTTP, no SSL) |
| `CEPH_DASHBOARD_PORT` | `8443` | Dashboard bind port |
| `CEPH_DASHBOARD_USER` | `admin` | Dashboard admin username |
| `CEPH_DASHBOARD_PASSWORD` | `admin` | Dashboard admin password (password policy is disabled) |
| `CEPH_PROMETHEUS` | `false` | Enable the mgr `prometheus` module (exporter on port 9283) |
| `CEPH_TEST_ORCHESTRATOR` | `false` | Enable Ceph's `test_orchestrator` backend so orchestrator-gated dashboard pages (Hosts, Services, Physical Disks) render. Data is synthetic; actions are no-ops |
| `CEPH_PROMETHEUS_API_URL` | (empty) | Prometheus URL the dashboard queries for its monitoring pages and native charts (e.g. `http://prometheus:9090`) |
| `CEPH_ALERTMANAGER_API_URL` | (empty) | Alertmanager URL the dashboard queries for its alerts and silences pages (e.g. `http://alertmanager:9093`) |
| `CEPH_GRAFANA_API_URL` | (empty) | Grafana URL the mgr uses to verify embedded dashboards (e.g. `http://grafana:3000`). Setting it enables Grafana embedding |
| `CEPH_GRAFANA_FRONTEND_API_URL` | (empty) | Grafana URL the browser uses for the iframe (e.g. `http://localhost:3000`). Falls back to `CEPH_GRAFANA_API_URL` |

Files placed in `/etc/ceph/ceph.conf.d/*.conf` are also appended to `ceph.conf` at startup — handy for injecting RGW Keystone or other settings via volume mounts or testcontainers file injection.

## Ports

| Port | Service |
|---|---|
| 3300 | Monitor (msgr2) |
| 6789 | Monitor (msgr1) |
| 8080 | RGW (S3 API) |
| 8443 | Dashboard (only when `CEPH_DASHBOARD=true`) |
| 9283 | Prometheus exporter (only when `CEPH_PROMETHEUS=true`) |

## Data Persistence

By default nothing persists between containers — each start creates a fresh cluster. To keep data across restarts, mount a volume at `/var/lib/ceph`; if it already contains a cluster the container reuses it instead of running `mkfs`.

```bash
docker run -d --name ceph -v ceph-data:/var/lib/ceph -p 8080:8080 ghcr.io/arttor/ceph-test:v20
```

> Use a **named volume** (as above), not a bind mount to a host path. On macOS, BlueStore `mkfs` fails on a Docker Desktop file share, so a bind mount for `/var/lib/ceph` does not work; named volumes live in the Docker VM and work fine.

Mount `/etc/ceph` to share `ceph.conf` and keyrings with a client container.

## Extra Configuration

Inject extra `ceph.conf` settings via env var:

```bash
docker run -d --name ceph \
  -e 'CEPH_EXTRA_CONF=
[client.rgw.demo]
rgw keystone api version = 3
rgw keystone url = http://keystone:5000
rgw s3 auth use keystone = true' \
  ghcr.io/arttor/ceph-test:v20
```

or a mounted config file:

```bash
echo '[client.rgw.demo]
rgw keystone api version = 3
rgw keystone url = http://keystone:5000' > keystone.conf

docker run -d --name ceph \
  -v $(pwd)/keystone.conf:/etc/ceph/ceph.conf.d/keystone.conf:ro \
  ghcr.io/arttor/ceph-test:v20
```

With testcontainers (Go), inject via the `Files` field:

```go
req := testcontainers.ContainerRequest{
    Image: "ghcr.io/arttor/ceph-test:v20",
    Files: []testcontainers.ContainerFile{{
        Reader:            strings.NewReader(keystoneConf),
        ContainerFilePath: "/etc/ceph/ceph.conf.d/keystone.conf",
        FileMode:          0o644,
    }},
}
```

## Building

```bash
docker build -t ceph-test:latest .
```

With a specific Ceph version:

```bash
docker build --build-arg CEPH_VERSION=v20.2.2 -t ceph-test:v20 .
```
