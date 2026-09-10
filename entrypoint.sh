#!/bin/bash
set -e

: "${MON_IP:=0.0.0.0}"
: "${CEPH_PUBLIC_NETWORK:=0.0.0.0/0}"
: "${CEPH_DEMO_UID:=demo}"
: "${CEPH_DEMO_ACCESS_KEY:=}"
: "${CEPH_DEMO_SECRET_KEY:=}"
: "${CEPH_DASHBOARD:=false}"
: "${CEPH_DASHBOARD_PORT:=8443}"
: "${CEPH_DASHBOARD_USER:=admin}"
: "${CEPH_DASHBOARD_PASSWORD:=admin}"
: "${CEPH_PROMETHEUS:=false}"
: "${CEPH_TEST_ORCHESTRATOR:=false}"
: "${CEPH_PROMETHEUS_API_URL:=}"
: "${CEPH_ALERTMANAGER_API_URL:=}"
: "${CEPH_GRAFANA_API_URL:=}"
: "${CEPH_GRAFANA_FRONTEND_API_URL:=}"
: "${CEPH_DEVICE_CLASS:=}"
: "${CEPH_CEPHFS:=false}"
: "${CEPH_CEPHFS_NAME:=cephfs}"
: "${CEPH_RGW_SEED:=false}"
: "${CEPH_RGW_SEED_BUCKET:=seed-bucket}"
: "${CEPH_RGW_SEED_OBJECTS:=5}"
: "${CEPH_FSID:=}"

if [ "$MON_IP" = "0.0.0.0" ]; then
    ACTUAL_IP=$(hostname -i | awk '{print $1}')
else
    ACTUAL_IP=$MON_IP
fi

echo "=== ceph-test starting ==="
echo "MON_IP=$ACTUAL_IP  NETWORK=$CEPH_PUBLIC_NETWORK"

# Data/config dirs may be empty volume mounts - make sure they exist.
mkdir -p /var/lib/ceph/mon/ceph-demo /var/lib/ceph/mgr/ceph-demo \
    /var/lib/ceph/osd/ceph-0 /var/lib/ceph/radosgw/ceph-rgw.demo \
    /var/lib/ceph/mds/ceph-demo /var/run/ceph /etc/ceph
chown ceph: /var/run/ceph

# Restore baked keyrings + ceph.conf if /etc/ceph is empty (fresh or empty volume).
if [ ! -f /etc/ceph/ceph.client.admin.keyring ]; then
    cp /opt/ceph-fast/keyring-backup/* /etc/ceph/
    cp /opt/ceph-fast/ceph.conf.baked /etc/ceph/ceph.conf
    chown -R ceph: /etc/ceph
fi

# Decide fresh mkfs vs start an existing cluster (e.g. persisted data volume).
if [ -f /var/lib/ceph/osd/ceph-0/mkfs_done ]; then
    FRESH=0
    FSID=$(cat /var/lib/ceph/osd/ceph-0/ceph_fsid)
    echo "Existing cluster found (fsid ${FSID})."
else
    FRESH=1
    FSID=${CEPH_FSID:-$(python3 -c 'import uuid; print(uuid.uuid4())')}
    echo "Initializing new cluster (fsid ${FSID})."
fi

# --- ceph.conf: set fsid, real mon IP, public network ---
sed -i "s|^fsid = .*|fsid = ${FSID}|" /etc/ceph/ceph.conf
sed -i "s|^mon host = .*|mon host = v2:${ACTUAL_IP}:3300/0|" /etc/ceph/ceph.conf
sed -i "s|^public network = .*|public network = ${CEPH_PUBLIC_NETWORK}|" /etc/ceph/ceph.conf

# --- Append extra config if provided (e.g. Keystone RGW settings) ---
if [ -n "$CEPH_EXTRA_CONF" ]; then
    echo "$CEPH_EXTRA_CONF" >> /etc/ceph/ceph.conf
fi
if ls /etc/ceph/ceph.conf.d/*.conf 1>/dev/null 2>&1; then
    for f in /etc/ceph/ceph.conf.d/*.conf; do
        cat "$f" >> /etc/ceph/ceph.conf
    done
fi

if [ "$FRESH" = "1" ]; then
    # --- mkfs mon, then mkfs osd against the running mon so it registers ---
    monmaptool --create --clobber --add demo "${ACTUAL_IP}:3300" --fsid "$FSID" /etc/ceph/monmap
    ceph-mon --cluster ceph --mkfs -i demo --monmap /etc/ceph/monmap \
        --keyring /etc/ceph/ceph.mon.keyring
    chown -R ceph: /var/lib/ceph/mon/ceph-demo /etc/ceph/monmap
    touch /var/lib/ceph/mon/ceph-demo/done

    echo "Starting mon..."
    ceph-mon --cluster ceph -i demo --public-addr "${ACTUAL_IP}:3300" --setuser ceph --setgroup ceph
    sleep 3

    ceph config set mon auth_allow_insecure_global_id_reclaim false
    ceph config set global osd_pool_default_pg_autoscale_mode off

    ceph auth get-or-create mgr.demo mon 'allow profile mgr' mds 'allow *' osd 'allow *' \
        -o /var/lib/ceph/mgr/ceph-demo/keyring
    chown -R ceph: /var/lib/ceph/mgr/ceph-demo
    ceph auth get-or-create osd.0 mon 'allow profile osd' osd 'allow *' mgr 'allow profile osd' \
        -o /var/lib/ceph/osd/ceph-0/keyring
    truncate -s 2147483648 /var/lib/ceph/osd/ceph-0/block
    chown -R ceph: /var/lib/ceph/osd/ceph-0
    ceph-osd --conf /etc/ceph/ceph.conf --osd-data /var/lib/ceph/osd/ceph-0 --mkfs -i 0
    echo "bluestore" > /var/lib/ceph/osd/ceph-0/type
    chown -R ceph: /var/lib/ceph/osd/ceph-0
    ceph auth get-or-create client.rgw.demo mon 'allow rw' osd 'allow rwx' \
        -o /var/lib/ceph/radosgw/ceph-rgw.demo/keyring
    chown -R ceph: /var/lib/ceph/radosgw/ceph-rgw.demo
else
    # --- Existing cluster: re-point the monmap at the current IP and start ---
    monmaptool --create --clobber --add demo "${ACTUAL_IP}:3300" --fsid "$FSID" /etc/ceph/monmap
    ceph-mon -i demo --inject-monmap /etc/ceph/monmap
    chown ceph: /etc/ceph/monmap

    echo "Starting mon..."
    ceph-mon --cluster ceph -i demo --public-addr "${ACTUAL_IP}:3300" --setuser ceph --setgroup ceph &
fi

sleep 1

echo "Starting mgr..."
ceph-mgr --cluster ceph -i demo --setuser ceph --setgroup ceph &

echo "Starting osd..."
ceph-osd --cluster ceph -i 0 --osd-data /var/lib/ceph/osd/ceph-0 --setuser ceph --setgroup ceph &

echo "Starting rgw..."
radosgw --cluster ceph -n client.rgw.demo -k /var/lib/ceph/radosgw/ceph-rgw.demo/keyring \
    --setuser ceph --setgroup ceph &

# --- Wait for cluster health ---
echo "Waiting for cluster..."
for i in $(seq 1 60); do
    if ceph health 2>/dev/null; then
        break
    fi
    sleep 1
done

# --- Set a CRUSH device class on every OSD ---
# Without it `ceph osd tree` shows no class and `ceph df detail` reports an
# empty stats_by_class, so per-class collectors see nothing.
if [ -n "$CEPH_DEVICE_CLASS" ]; then
    echo "Setting CRUSH device class ${CEPH_DEVICE_CLASS} on OSDs..."
    OSDS=""
    for i in $(seq 1 30); do
        OSDS=$(ceph osd ls 2>/dev/null || true)
        UP=$(ceph osd stat -f json 2>/dev/null | grep -o '"num_up_osds":[0-9]*' | cut -d: -f2)
        if [ -n "$OSDS" ] && [ "${UP:-0}" -gt 0 ]; then
            break
        fi
        sleep 1
    done
    for osd in $OSDS; do
        # An OSD already bound to another class rejects set-device-class.
        ceph osd crush rm-device-class "osd.${osd}" >/dev/null 2>&1 || true
        ceph osd crush set-device-class "$CEPH_DEVICE_CLASS" "osd.${osd}"
    done
fi

# --- Create a CephFS filesystem ---
# `ceph fs volume create` only creates the pools and the fs here ("no MDS
# daemons created"): spawning the MDS needs an orchestrator, which this image
# does not run, so the mds daemon is started by hand like mon/mgr/osd/rgw.
if [ "$CEPH_CEPHFS" = "true" ] || [ "$CEPH_CEPHFS" = "1" ]; then
    # `fs volume create` belongs to the mgr's volumes module: the mon only
    # accepts it once the active mgr has registered its module commands, which
    # lags the health loop above (that one only proves the mon). Run it too
    # early - as a slow CI runner does - and the mon answers "no valid command
    # found" / EINVAL and set -e kills the container.
    echo "Waiting for mgr module commands..."
    for i in $(seq 1 60); do
        if ceph mgr stat 2>/dev/null | grep -q '"available": *true' \
            && ceph fs volume ls >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    echo "Creating CephFS ${CEPH_CEPHFS_NAME}..."
    ceph fs volume create "$CEPH_CEPHFS_NAME"

    ceph auth get-or-create mds.demo mon 'profile mds' mgr 'profile mds' \
        mds 'allow *' osd 'allow *' -o /var/lib/ceph/mds/ceph-demo/keyring
    chown -R ceph: /var/lib/ceph/mds/ceph-demo

    echo "Starting mds..."
    ceph-mds --cluster ceph -i demo --setuser ceph --setgroup ceph &

    for i in $(seq 1 60); do
        if ceph fs status "$CEPH_CEPHFS_NAME" 2>/dev/null | grep -q active; then
            echo "CephFS ${CEPH_CEPHFS_NAME} active."
            break
        fi
        sleep 1
    done
fi

# --- Create S3 demo user ---
if [ -n "$CEPH_DEMO_ACCESS_KEY" ] && [ -n "$CEPH_DEMO_SECRET_KEY" ]; then
    echo "Creating S3 demo user..."
    for i in $(seq 1 30); do
        if radosgw-admin user create \
            --uid="$CEPH_DEMO_UID" \
            --display-name="Ceph demo user" \
            --access-key="$CEPH_DEMO_ACCESS_KEY" \
            --secret-key="$CEPH_DEMO_SECRET_KEY" 2>/dev/null; then
            radosgw-admin caps add \
                --caps="buckets=*;users=*;usage=*;metadata=*" \
                --uid="$CEPH_DEMO_UID" 2>/dev/null || true
            echo "S3 user created."
            break
        fi
        sleep 1
    done
fi

# --- Seed RGW with a bucket and a few objects ---
# radosgw-admin cannot write objects and the image ships no S3 client, so the
# objects go in over the S3 API with a v2 signature (openssl + curl, both
# already present). Uses the demo user, creating it if it does not exist yet.
if [ "$CEPH_RGW_SEED" = "true" ] || [ "$CEPH_RGW_SEED" = "1" ]; then
    echo "Seeding RGW (user ${CEPH_DEMO_UID}, bucket ${CEPH_RGW_SEED_BUCKET})..."
    radosgw-admin user info --uid="$CEPH_DEMO_UID" >/dev/null 2>&1 \
        || radosgw-admin user create --uid="$CEPH_DEMO_UID" \
            --display-name="Ceph demo user" >/dev/null
    S3_KEYS=$(radosgw-admin user info --uid="$CEPH_DEMO_UID" --format=json 2>/dev/null \
        | python3 -c 'import json,sys; k=json.load(sys.stdin)["keys"][0]; print(k["access_key"], k["secret_key"])')
    S3_ACCESS=${S3_KEYS% *}
    S3_SECRET=${S3_KEYS#* }

    s3_put() { # <path> <content-type> [curl args...]
        local path=$1 ctype=$2 now sig
        shift 2
        now=$(date -R -u)
        sig=$(printf '%s\n\n%s\n%s\n%s' PUT "$ctype" "$now" "$path" \
            | openssl sha1 -hmac "$S3_SECRET" -binary | base64)
        curl -sS -o /dev/null -X PUT -H "Date: ${now}" -H "Content-Type: ${ctype}" \
            -H "Authorization: AWS ${S3_ACCESS}:${sig}" "$@" \
            "http://127.0.0.1:8080${path}"
    }

    for i in $(seq 1 30); do
        if curl -s -o /dev/null http://127.0.0.1:8080; then
            break
        fi
        sleep 1
    done

    s3_put "/${CEPH_RGW_SEED_BUCKET}" ""
    for i in $(seq 1 "$CEPH_RGW_SEED_OBJECTS"); do
        printf 'ceph-test seed object %s\n' "$i" \
            | s3_put "/${CEPH_RGW_SEED_BUCKET}/seed-${i}.txt" text/plain --data-binary @-
    done

    for i in $(seq 1 30); do
        if radosgw-admin bucket stats --bucket="$CEPH_RGW_SEED_BUCKET" 2>/dev/null \
            | grep -q '"num_objects": [1-9]'; then
            echo "RGW seeded: ${CEPH_RGW_SEED_OBJECTS} objects in ${CEPH_RGW_SEED_BUCKET}."
            break
        fi
        sleep 1
    done
fi

# --- Enable the test orchestrator backend ---
# Ceph's test_orchestrator module provides a fake orchestrator so dashboard
# pages that require one (Hosts, Services, Physical Disks, cluster expansion,
# multi-cluster onboarding) work. Data is synthetic and actions are no-ops.
if [ "$CEPH_TEST_ORCHESTRATOR" = "true" ] || [ "$CEPH_TEST_ORCHESTRATOR" = "1" ]; then
    echo "Enabling test_orchestrator backend..."
    ceph mgr module enable test_orchestrator --force || true
    # Enabling the module makes the mgr reload it; "orch set backend" only
    # sticks once the module is active, so retry until the backend reports ready.
    for i in $(seq 1 30); do
        ceph orch set backend test_orchestrator >/dev/null 2>&1 || true
        if ceph orch status 2>/dev/null | grep -q "Available: Yes"; then
            echo "test_orchestrator backend active."
            break
        fi
        sleep 1
    done
fi

# --- Enable Prometheus exporter (mgr module) ---
# Exports Ceph metrics on :9283 for an external Prometheus to scrape. This is
# the data source behind the dashboard's embedded Grafana graphs.
if [ "$CEPH_PROMETHEUS" = "true" ] || [ "$CEPH_PROMETHEUS" = "1" ]; then
    echo "Enabling Prometheus mgr module (exporter on :9283)..."
    ceph mgr module enable prometheus --force || true
fi

# --- Enable Ceph dashboard (mgr module) ---
if [ "$CEPH_DASHBOARD" = "true" ] || [ "$CEPH_DASHBOARD" = "1" ]; then
    echo "Enabling Ceph dashboard on port ${CEPH_DASHBOARD_PORT}..."
    # Dashboard setup is best-effort: don't let a failing command kill the
    # container (the main "ceph -w" below must still run).
    set +e

    ceph mgr module enable dashboard --force

    # The mgr registers the dashboard's config options AND its "ceph dashboard"
    # sub-commands only after it finishes loading the module, a second or two
    # behind "module enable". The sub-commands come up last, so gate on one of
    # them: once set-pwd-policy-enabled succeeds, everything below is safe.
    # Disabling the policy also lets weak test passwords (e.g. "admin") through.
    for i in $(seq 1 30); do
        if ceph dashboard set-pwd-policy-enabled false 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # Plain HTTP (no SSL) keeps this test image simple.
    ceph config set mgr mgr/dashboard/ssl false
    ceph config set mgr mgr/dashboard/server_addr 0.0.0.0
    ceph config set mgr mgr/dashboard/server_port "$CEPH_DASHBOARD_PORT"

    printf '%s' "$CEPH_DASHBOARD_PASSWORD" > /tmp/dashboard_pw
    ceph dashboard ac-user-create "$CEPH_DASHBOARD_USER" \
        -i /tmp/dashboard_pw administrator 2>/dev/null \
        || ceph dashboard ac-user-set-password "$CEPH_DASHBOARD_USER" \
            -i /tmp/dashboard_pw 2>/dev/null
    rm -f /tmp/dashboard_pw

    # Point the dashboard at Prometheus so its monitoring/alerts pages and
    # native charts (query_range) work. This is the mgr-facing URL; the backend
    # proxies these queries, the browser does not reach Prometheus directly.
    if [ -n "$CEPH_PROMETHEUS_API_URL" ]; then
        echo "Configuring Prometheus API host (${CEPH_PROMETHEUS_API_URL})..."
        ceph dashboard set-prometheus-api-host "$CEPH_PROMETHEUS_API_URL"
        ceph dashboard set-prometheus-api-ssl-verify false
    fi

    # Point the dashboard at Alertmanager so its alerts/silences pages work.
    if [ -n "$CEPH_ALERTMANAGER_API_URL" ]; then
        echo "Configuring Alertmanager API host (${CEPH_ALERTMANAGER_API_URL})..."
        ceph dashboard set-alertmanager-api-host "$CEPH_ALERTMANAGER_API_URL"
        ceph dashboard set-alertmanager-api-ssl-verify false
    fi

    # Point the dashboard at an external Grafana for the embedded graphs.
    # Requires a Grafana + Prometheus stack (see docker-compose.grafana.yml).
    if [ -n "$CEPH_GRAFANA_API_URL" ]; then
        echo "Configuring Grafana embedding (api-url: ${CEPH_GRAFANA_API_URL})..."
        ceph dashboard set-grafana-api-url "$CEPH_GRAFANA_API_URL"
        # Test setup uses plain HTTP / self-signed certs, so skip verification.
        ceph dashboard set-grafana-api-ssl-verify false
        # URL the browser uses for the iframe; falls back to the api-url.
        ceph dashboard set-grafana-frontend-api-url \
            "${CEPH_GRAFANA_FRONTEND_API_URL:-$CEPH_GRAFANA_API_URL}"
    fi

    # Reload module so ssl/addr/port changes take effect.
    ceph mgr module disable dashboard
    ceph mgr module enable dashboard

    for i in $(seq 1 30); do
        url=$(ceph mgr services 2>/dev/null | grep -o 'http[s]*://[^"]*')
        if [ -n "$url" ]; then
            echo "Dashboard available at: $url (login: ${CEPH_DASHBOARD_USER})"
            break
        fi
        sleep 1
    done

    set -e
fi

echo "=== ceph-test ready ==="

exec ceph -w
