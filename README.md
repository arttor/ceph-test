# ceph-test

Single-node Ceph cluster for testing optimised for fast startup. OSD filesystem is initialized at build time, so the container only starts daemons at runtime.

Based on `quay.io/ceph/ceph`. Multiarch: `linux/amd64` and `linux/arm64`.

## Motivation

The deprecated `quay.io/ceph/demo` image runs `ceph-osd --mkfs` at every container start, which takes 30-40 seconds. This image moves that to build time.

Startup comparison (to full S3 readiness):

| Image | Startup |
|---|---|
| quay.io/ceph/demo | ~40s |
| ceph-test (this) | ~15-18s |

Additionally, `ceph/demo` does not publish multiarch images (separate tags for arm64/amd64). This image is multiarch.

## Usage

```bash
docker run -d --name ceph \
  -p 8080:8080 \
  ghcr.io/arttor/ceph-test:v19
```

With S3 user:

```bash
docker run -d --name ceph \
  -e CEPH_DEMO_ACCESS_KEY=mykey \
  -e CEPH_DEMO_SECRET_KEY=mysecret \
  -p 8080:8080 \
  ghcr.io/arttor/ceph-test:v19
```

Check status:

```bash
docker exec ceph ceph -s
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MON_IP` | `0.0.0.0` (auto-detect) | Monitor bind address |
| `CEPH_PUBLIC_NETWORK` | `0.0.0.0/0` | Public network CIDR |
| `CEPH_DEMO_UID` | `demo` | S3 user UID (created only if access key is set) |
| `CEPH_DEMO_ACCESS_KEY` | (empty) | S3 access key. If set, creates an RGW user at startup |
| `CEPH_DEMO_SECRET_KEY` | (empty) | S3 secret key |
| `CEPH_EXTRA_CONF` | (empty) | Extra lines appended to `ceph.conf` before daemons start |

Files placed in `/etc/ceph/ceph.conf.d/*.conf` are also appended to `ceph.conf` at startup. This is useful for injecting RGW Keystone configuration or other settings via volume mounts or testcontainers file injection.

## Ports

| Port | Service |
|---|---|
| 3300 | Monitor (msgr2) |
| 6789 | Monitor (msgr1) |
| 8080 | RGW (S3 API) |

## How It Works

The Dockerfile runs a full Ceph bootstrap at build time:

1. Generates FSID, keyrings, monmap
2. Bootstraps monitor (`ceph-mon --mkfs`)
3. Starts a temporary monitor
4. Creates MGR, OSD, RGW auth keyrings
5. Initializes OSD with BlueStore (`ceph-osd --mkfs`)
6. Stops the temporary monitor

At runtime, the entrypoint:

1. Patches `ceph.conf` and monmap with the real `MON_IP`
2. Restores keyrings if `/etc/ceph` is a volume mount
3. Starts mon, mgr, osd, rgw daemons
4. Creates S3 user (if credentials are provided via env vars)

## Data Persistence

OSD data lives inside the container image. Nothing is persisted between restarts. This is by design for testing.

The only volume you may want to mount is `/etc/ceph` to share keyrings with other containers (e.g., a Ceph client that needs `ceph.conf` and the admin keyring).

## Extra Configuration

To inject additional settings into `ceph.conf` before daemons start, use either:

**Environment variable:**

```bash
docker run -d --name ceph \
  -e 'CEPH_EXTRA_CONF=
[client.rgw.demo]
rgw keystone api version = 3
rgw keystone url = http://keystone:5000
rgw s3 auth use keystone = true' \
  ghcr.io/arttor/ceph-test:v19
```

**Config file mount** (for more complex configs):

```bash
echo '[client.rgw.demo]
rgw keystone api version = 3
rgw keystone url = http://keystone:5000' > keystone.conf

docker run -d --name ceph \
  -v $(pwd)/keystone.conf:/etc/ceph/ceph.conf.d/keystone.conf:ro \
  ghcr.io/arttor/ceph-test:v19
```

With testcontainers (Go), inject via the `Files` field:

```go
req := testcontainers.ContainerRequest{
    Image: "ghcr.io/arttor/ceph-test:v19",
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
docker build --build-arg CEPH_VERSION=v20 -t ceph-test:v20 .
```

Requires Ceph v19 or later (v18 segfaults during OSD mkfs in Docker build layers).
