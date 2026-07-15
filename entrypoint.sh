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
    /var/lib/ceph/osd/ceph-0 /var/lib/ceph/radosgw/ceph-rgw.demo /var/run/ceph /etc/ceph
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
