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
: "${CEPH_TEST_ORCHESTRATOR_DATA:=}"
: "${CEPH_TEST_ORCHESTRATOR_IMAGE:=}"
: "${CEPH_TEST_ORCHESTRATOR_IMAGE_ID:=}"
: "${CEPH_PROMETHEUS_API_URL:=}"
: "${CEPH_ALERTMANAGER_API_URL:=}"
: "${CEPH_GRAFANA_API_URL:=}"
: "${CEPH_GRAFANA_FRONTEND_API_URL:=}"
: "${CEPH_DEVICE_CLASS:=}"
: "${CEPH_RGW:=true}"
: "${CEPH_RBD_POOL:=}"
: "${CEPH_CEPHFS:=false}"
: "${CEPH_CEPHFS_NAME:=cephfs}"
: "${CEPH_RGW_SEED:=false}"
: "${CEPH_RGW_SEED_BUCKET:=seed-bucket}"
: "${CEPH_RGW_SEED_OBJECTS:=5}"
: "${CEPH_FSID:=}"
: "${CEPH_WAIT_TIMEOUT:=300}"

is_true() { [ "$1" = "true" ] || [ "$1" = "1" ]; }

# --- Daemon supervision ---
# Daemons run in the foreground (-f) as children of this script, so it sees
# when one exits and stops the container with the reason, instead of running
# on with a broken cluster. The mgr respawns itself on module changes with
# execv, which keeps its pid.
declare -A DAEMONS # pid -> daemon name, as in its log file name
WATCH_PID=

# A daemon's own stdout/stderr (startup noise, mgr module tracebacks) goes to
# a file next to its log, as when daemons forked into the background.
start_daemon() { # <name> <command...>
    local name=$1
    shift
    echo "Starting ${name}..."
    "$@" >>"/var/log/ceph/ceph-${name}.out" 2>&1 &
    DAEMONS[$!]=$name
}

stop_daemons() {
    kill -TERM "${!DAEMONS[@]}" $WATCH_PID 2>/dev/null || true
}

fail() {
    # A setup step (a background subshell) only exits: the main script sees
    # it fail and stops the container.
    if [ "$BASHPID" = "$$" ]; then
        stop_daemons
    fi
    exit 1
}

daemon_exited() { # <pid> <status>
    local name=${DAEMONS[$1]}
    local f
    echo "FAILED: ${name} exited with status $2" >&2
    for f in "/var/log/ceph/ceph-${name}.out" "/var/log/ceph/ceph-${name}.log"; do
        if [ -s "$f" ]; then
            echo "--- tail of ${f} ---" >&2
            tail -n 20 "$f" >&2
        fi
    done
    fail
}

check_daemons() {
    local pid status
    for pid in "${!DAEMONS[@]}"; do
        kill -0 "$pid" 2>/dev/null && continue
        # In a setup step, leave reporting to the main script: the daemon is
        # its child, not the step's.
        [ "$BASHPID" = "$$" ] || exit 1
        if wait "$pid"; then status=0; else status=$?; fi
        daemon_exited "$pid" "$status"
    done
}

# docker stop: a throwaway test container needs no graceful shutdown, so the
# daemons are killed: Ceph's stores (mon rocksdb, bluestore) survive that, so a
# persisted cluster still restarts. Except RGW's watches on its control objects:
# the OSD keeps a killed client's watches for osd_client_watch_timeout (30s)
# after a restart, and the next RGW's first metadata write (a bucket or user
# create) waits that long for the dead watcher. RGW removes them right after
# SIGTERM (exiting takes ~30s more), so SIGTERM it, wait until they are gone
# (at most 3s, well inside docker's 10s), then kill everything.
rgw_unwatched() { # true once every RGW control object is known to have no watcher
    local objs obj
    objs=$(rados -p default.rgw.control ls) || return 1
    for obj in $objs; do
        [ -z "$(rados -p default.rgw.control listwatchers "$obj")" ] || return 1
    done
}
shutdown() {
    local pid end=$((SECONDS + 3))
    echo "Stopping..."
    for pid in "${!DAEMONS[@]}"; do
        if [ "${DAEMONS[$pid]}" = client.rgw.demo ]; then
            kill -TERM "$pid" 2>/dev/null || true
            # A probe that errors or times out counts as still watched.
            until [ "$SECONDS" -ge "$end" ] \
                || timeout "$((end - SECONDS))" bash -c "$(declare -f rgw_unwatched); rgw_unwatched" 2>/dev/null; do
                sleep 0.05
            done
        fi
    done
    kill -KILL "${!DAEMONS[@]}" $WATCH_PID 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# wait_for <what> <command> [args...]: run the command (a binary or a function
# defined here) until it succeeds, polling every 0.2s. Each attempt is capped
# at 60s, since ceph commands block while the cluster cannot serve them. The
# container fails with the command's last output after CEPH_WAIT_TIMEOUT
# seconds, and at once if a daemon exits meanwhile. Only the deadline decides
# failure, so a slow machine just takes longer.
wait_for() {
    local what=$1 deadline=$((SECONDS + CEPH_WAIT_TIMEOUT)) out
    shift
    until out=$(timeout -k 5 60 bash -c "$(declare -f); \"\$@\"" _ "$@" 2>&1); do
        check_daemons
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "FAILED: ${what} not reached in ${CEPH_WAIT_TIMEOUT}s: ${out}" >&2
            fail
        fi
        sleep 0.2
    done
}

# --- Readiness markers ---
# Each component touches a file here when it is ready; ceph-test-health (the
# Docker HEALTHCHECK) reads them, so health and the log lines always agree.
# "enabled" lists the components this start will mark. Cleared on every start:
# after a docker restart the previous run's markers would report ready early.
STATE_DIR=/run/ceph-test
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
mark_ready() { # <component>
    touch "${STATE_DIR}/$1"
}

if [ "$MON_IP" = "0.0.0.0" ]; then
    ACTUAL_IP=$(hostname -i | awk '{print $1}')
else
    ACTUAL_IP=$MON_IP
fi

# Without RGW, everything that needs it is skipped too.
S3_USER=false
[ -n "$CEPH_DEMO_ACCESS_KEY" ] && [ -n "$CEPH_DEMO_SECRET_KEY" ] && S3_USER=true
if ! is_true "$CEPH_RGW"; then
    if is_true "$S3_USER" || is_true "$CEPH_RGW_SEED"; then
        echo "WARNING: CEPH_RGW=false, ignoring the S3 user and RGW seed settings" >&2
    fi
    S3_USER=false
    CEPH_RGW_SEED=false
fi

{
    echo base
    is_true "$CEPH_RGW" && echo rgw
    is_true "$S3_USER" && echo s3-user
    is_true "$CEPH_RGW_SEED" && echo rgw-seed
    [ -n "$CEPH_DEVICE_CLASS" ] && echo device-class
    [ -n "$CEPH_RBD_POOL" ] && echo rbd
    is_true "$CEPH_CEPHFS" && echo cephfs
    is_true "$CEPH_TEST_ORCHESTRATOR" && echo orchestrator
    is_true "$CEPH_PROMETHEUS" && echo prometheus
    is_true "$CEPH_DASHBOARD" && echo dashboard
    echo all
} > "${STATE_DIR}/enabled"

echo "=== ceph-test starting ==="
echo "MON_IP=$ACTUAL_IP  NETWORK=$CEPH_PUBLIC_NETWORK"

# Data/config dirs may be empty volume mounts - make sure they exist.
mkdir -p /var/lib/ceph/mon/ceph-demo /var/lib/ceph/mgr/ceph-demo \
    /var/lib/ceph/osd/ceph-0 /var/lib/ceph/radosgw/ceph-rgw.demo \
    /var/lib/ceph/mds/ceph-demo /var/run/ceph /etc/ceph
chown ceph: /var/run/ceph

# Restore baked keyrings if /etc/ceph is empty (fresh or empty volume).
# chown only the keyrings: /etc/ceph may hold read-only mounts (ceph.conf.d).
if [ ! -f /etc/ceph/ceph.client.admin.keyring ]; then
    cp /opt/ceph-fast/keyring-backup/* /etc/ceph/
    chown ceph: /etc/ceph/*.keyring
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

# --- ceph.conf: rebuilt from the baked template on every start ---
# Reusing the previous start's file (persisted /etc/ceph) would pile up the
# extra config appended below, and settings removed from CEPH_EXTRA_CONF would
# stick. Built aside and moved into place in one step, so a client sharing
# /etc/ceph never reads a half-written file.
CONF_NEW=/etc/ceph/.ceph.conf.new
cp /opt/ceph-fast/ceph.conf.baked "$CONF_NEW"
sed -i -e "s|^fsid = .*|fsid = ${FSID}|" \
    -e "s|^mon host = .*|mon host = v2:${ACTUAL_IP}:3300/0|" \
    -e "s|^public network = .*|public network = ${CEPH_PUBLIC_NETWORK}|" "$CONF_NEW"

# --- Append extra config if provided (e.g. Keystone RGW settings) ---
# The baked file ends in [client.rgw.demo], so each snippet is opened with
# [global]: lines before the snippet's own section header (or a snippet with
# none) apply cluster-wide instead of only to RGW.
if [ -n "$CEPH_EXTRA_CONF" ]; then
    printf '\n[global]\n%s\n' "$CEPH_EXTRA_CONF" >> "$CONF_NEW"
fi
if ls /etc/ceph/ceph.conf.d/*.conf 1>/dev/null 2>&1; then
    for f in /etc/ceph/ceph.conf.d/*.conf; do
        printf '\n[global]\n' >> "$CONF_NEW"
        cat "$f" >> "$CONF_NEW"
    done
fi
chown ceph: "$CONF_NEW"
mv -f "$CONF_NEW" /etc/ceph/ceph.conf

# The OSD size is set at mkfs; an existing cluster keeps it.
if [ "$FRESH" = "0" ] \
    && OSD_SIZE=$(stat -c %s /var/lib/ceph/osd/ceph-0/block) \
    && CONF_SIZE=$(ceph-conf --show-config-value bluestore_block_size -n osd.0) \
    && [ "$OSD_SIZE" != "$CONF_SIZE" ]; then
    echo "WARNING: bluestore_block_size=${CONF_SIZE} ignored, the existing OSD keeps its size ${OSD_SIZE} (set at mkfs)" >&2
fi

# --- Start the mon ---
# A fresh cluster gets every daemon's key through the mon's mkfs keyring, so
# they are in its auth database from the start: no `ceph auth` round trips.
gen_key() { # <keyring> <entity> <ceph-authtool cap args...>
    local keyring=$1 entity=$2
    shift 2
    ceph-authtool "$keyring" --create-keyring --gen-key -n "$entity" "$@" >/dev/null
    ceph-authtool /tmp/mkfs.keyring --import-keyring "$keyring" >/dev/null
}
if [ "$FRESH" = "1" ]; then
    cp /etc/ceph/ceph.mon.keyring /tmp/mkfs.keyring
    gen_key /var/lib/ceph/mgr/ceph-demo/keyring mgr.demo \
        --cap mon 'allow profile mgr' --cap mds 'allow *' --cap osd 'allow *'
    gen_key /var/lib/ceph/osd/ceph-0/keyring osd.0 \
        --cap mon 'allow profile osd' --cap osd 'allow *' --cap mgr 'allow profile osd'
    if is_true "$CEPH_RGW"; then
        gen_key /var/lib/ceph/radosgw/ceph-rgw.demo/keyring client.rgw.demo \
            --cap mon 'allow rw' --cap osd 'allow rwx'
    fi
    if is_true "$CEPH_CEPHFS"; then
        gen_key /var/lib/ceph/mds/ceph-demo/keyring mds.demo \
            --cap mon 'profile mds' --cap mgr 'profile mds' --cap mds 'allow *' --cap osd 'allow *'
    fi
    monmaptool --create --clobber --add demo "${ACTUAL_IP}:3300" --fsid "$FSID" /etc/ceph/monmap
    ceph-mon --cluster ceph --mkfs -i demo --monmap /etc/ceph/monmap --keyring /tmp/mkfs.keyring
    rm -f /tmp/mkfs.keyring
    touch /var/lib/ceph/mon/ceph-demo/done
    chown -R ceph: /var/lib/ceph/mon/ceph-demo /var/lib/ceph/mgr/ceph-demo \
        /var/lib/ceph/osd/ceph-0 /var/lib/ceph/radosgw/ceph-rgw.demo /var/lib/ceph/mds/ceph-demo
else
    # --- Existing cluster: re-point the monmap at the current IP ---
    monmaptool --create --clobber --add demo "${ACTUAL_IP}:3300" --fsid "$FSID" /etc/ceph/monmap
    ceph-mon -i demo --inject-monmap /etc/ceph/monmap
fi
chown ceph: /etc/ceph/monmap
start_daemon mon.demo ceph-mon -f --cluster ceph -i demo --public-addr "${ACTUAL_IP}:3300" \
    --setuser ceph --setgroup ceph
wait_for "mon" ceph mon stat

# --- Before mgr/osd/rgw start ---
# Settings they must see from the start. Each is a mon round trip, so they
# run in parallel, alongside the OSD's mkfs on a fresh cluster:
#  - pg autoscaling off before any pool exists (rgw and the mgr create pools);
#  - mgr modules enabled before the mgr starts: enabling one later makes the
#    mgr respawn, dropping it and its commands for a few seconds;
#  - the dashboard's listen settings set before it loads, so it needs no
#    reload (another respawn).
run_parallel() { # <function...>: run concurrently, fail if any fails
    local f pid failed=
    local -A jobs=()
    for f in "$@"; do
        "$f" &
        jobs[$!]=$f
    done
    for pid in "${!jobs[@]}"; do
        wait "$pid" || failed+=" ${jobs[$pid]}"
    done
    if [ -n "$failed" ]; then
        check_daemons
        echo "FAILED: startup step(s)${failed} failed" >&2
        fail
    fi
}
osd_prepare() {
    # mkfs creates the block file (sparse) at bluestore_block_size from
    # ceph.conf, but keeps the size of an existing one, e.g. left over from a
    # failed start.
    rm -f /var/lib/ceph/osd/ceph-0/block
    chown -R ceph: /var/lib/ceph/osd/ceph-0
    ceph-osd --conf /etc/ceph/ceph.conf --osd-data /var/lib/ceph/osd/ceph-0 --mkfs -i 0
    echo "bluestore" > /var/lib/ceph/osd/ceph-0/type
    chown -R ceph: /var/lib/ceph/osd/ceph-0
    # Register osd.0 in the osdmap before it starts, as ceph-volume does.
    # Otherwise the OSD's own fallback ("osd create", then retry the crush
    # create-or-move) runs, and on v21 that retry sends an empty command
    # (moved-from string) - the OSD exits with "unparseable JSON".
    wait_for "osd.0 registered" ceph osd new "$(cat /var/lib/ceph/osd/ceph-0/fsid)" 0
}
config_global_id() {
    wait_for "global_id config" ceph config set mon auth_allow_insecure_global_id_reclaim false
}
config_autoscale() {
    wait_for "autoscale config" ceph config set global osd_pool_default_pg_autoscale_mode off
}
enable_prometheus() {
    wait_for "prometheus module" ceph mgr module enable prometheus --force
}
enable_test_orchestrator() {
    wait_for "test_orchestrator module" ceph mgr module enable test_orchestrator --force
}
enable_dashboard() {
    # Plain HTTP (no SSL) keeps this test image simple. --force: the mon only
    # knows a module's options once a mgr has reported them, which on a fresh
    # cluster it has not yet.
    wait_for "dashboard ssl" ceph config set mgr mgr/dashboard/ssl false --force
    wait_for "dashboard addr" ceph config set mgr mgr/dashboard/server_addr 0.0.0.0 --force
    wait_for "dashboard port" ceph config set mgr mgr/dashboard/server_port "$CEPH_DASHBOARD_PORT" --force
    wait_for "dashboard module" ceph mgr module enable dashboard --force
}
# Keys a persisted cluster may lack, if it first started without the feature.
ensure_rgw_key() {
    [ -s /var/lib/ceph/radosgw/ceph-rgw.demo/keyring ] && return
    wait_for "client.rgw.demo key" ceph auth get-or-create client.rgw.demo \
        mon 'allow rw' osd 'allow rwx' -o /var/lib/ceph/radosgw/ceph-rgw.demo/keyring
    chown -R ceph: /var/lib/ceph/radosgw/ceph-rgw.demo
}
ensure_mds_key() {
    [ -s /var/lib/ceph/mds/ceph-demo/keyring ] && return
    wait_for "mds.demo key" ceph auth get-or-create mds.demo mon 'profile mds' mgr 'profile mds' \
        mds 'allow *' osd 'allow *' -o /var/lib/ceph/mds/ceph-demo/keyring
    chown -R ceph: /var/lib/ceph/mds/ceph-demo
}
# On an existing cluster, the daemons of the previous run (killed, or gone with
# the container) are still in the maps as up: the osdmap holds osd.0's old
# address, the mgrmap and fsmap the old active mgr and mds. Clients started
# now (RGW, the readiness waits) would believe them: RGW's first read goes to
# the dead OSD address and waits ~10s for a newer map, and the readiness
# checks would pass before the new daemons are up. Mark them down first.
# Both fail commands succeed if the daemon is not in the map. mds fail refuses
# an MDS with trim/cache health warnings (likely after a kill) unless confirmed.
mark_previous_down() {
    wait_for "osd.0 marked down" ceph osd down 0
    wait_for "previous mgr failed" ceph mgr fail demo
    if is_true "$CEPH_CEPHFS"; then
        wait_for "previous mds failed" ceph mds fail demo --yes-i-really-mean-it
    fi
}
PRESTART=()
if [ "$FRESH" = "1" ]; then
    PRESTART+=(osd_prepare config_global_id config_autoscale)
else
    PRESTART+=(mark_previous_down)
fi
is_true "$CEPH_RGW" && PRESTART+=(ensure_rgw_key)
is_true "$CEPH_CEPHFS" && PRESTART+=(ensure_mds_key)
is_true "$CEPH_PROMETHEUS" && PRESTART+=(enable_prometheus)
is_true "$CEPH_TEST_ORCHESTRATOR" && PRESTART+=(enable_test_orchestrator)
is_true "$CEPH_DASHBOARD" && PRESTART+=(enable_dashboard)
if [ ${#PRESTART[@]} -gt 0 ]; then
    run_parallel "${PRESTART[@]}"
fi

# --- Start the other daemons ---
# The MDS starts with the rest: it stays standby until the CephFS step
# creates the filesystem (spawning it would need an orchestrator, which this
# image does not run).
start_daemon mgr.demo ceph-mgr -f --cluster ceph -i demo --setuser ceph --setgroup ceph
start_daemon osd.0 ceph-osd -f --cluster ceph -i 0 --osd-data /var/lib/ceph/osd/ceph-0 \
    --setuser ceph --setgroup ceph
if is_true "$CEPH_RGW"; then
    start_daemon client.rgw.demo radosgw -f --cluster ceph -n client.rgw.demo \
        -k /var/lib/ceph/radosgw/ceph-rgw.demo/keyring --setuser ceph --setgroup ceph
fi
if is_true "$CEPH_CEPHFS"; then
    start_daemon mds.demo ceph-mds -f --cluster ceph -i demo --setuser ceph --setgroup ceph
fi

# --- Setup steps ---
# Each step runs in the background and waits for exactly what it needs, so
# the steps overlap and none depends on another's waits or on their order.
# The main loop at the end supervises them and the daemons.
mgr_available() {
    ceph mgr stat | grep -q '"available": *true'
}
osd_up() {
    ceph osd stat -f json | grep -q '"num_up_osds":[1-9]'
}
# The mgr can drop the OSD's first stats report (it is not yet "in" in the
# mgr's osdmap), and `ceph df` then reads 0 until the next one, ~5s later.
# The mon's copy (ceph status, librados cluster stats) follows on the mgr's
# next tick (~2s); waiting for it too would add that to every start.
osd_stats() {
    ceph df -f json | grep -q '"total_bytes": *[1-9]'
}

# --- Base readiness: mon, mgr and osd, with the OSD's stats in the mgr ---
# The "ready" line and Docker health mean exactly this. RGW and the optional
# features log and mark their own readiness (see ceph-test-health).
step_base() {
    wait_for "mgr available" mgr_available
    wait_for "OSD up" osd_up
    wait_for "OSD stats" osd_stats
    echo "=== ceph-test ready ==="
    mark_ready base
}

# --- Set a CRUSH device class on every OSD ---
# Without it `ceph osd tree` shows no class and `ceph df detail` reports an
# empty stats_by_class, so per-class collectors see nothing.
set_device_class() { # <class> <osd id>
    # An OSD already bound to another class rejects set-device-class.
    ceph osd crush rm-device-class "osd.$2" >/dev/null 2>&1 || true
    ceph osd crush set-device-class "$1" "osd.$2"
}
step_device_class() {
    local osd osds
    echo "Setting CRUSH device class ${CEPH_DEVICE_CLASS} on OSDs..."
    wait_for "OSD up" osd_up
    osds=$(timeout 60 ceph osd ls)
    for osd in $osds; do
        wait_for "device class on osd.${osd}" set_device_class "$CEPH_DEVICE_CLASS" "$osd"
    done
    echo "CRUSH device class ${CEPH_DEVICE_CLASS} set."
    mark_ready device-class
}

# --- Create an RBD pool ---
# Runs on every start, so it also applies to an existing (persisted) cluster:
# pool create succeeds if the pool exists and rbd pool init is idempotent.
# rbd pool init writes objects into the pool, so it blocks until the OSD is up
# and the pool's PGs are active; wait_for caps and retries each attempt.
rbd_pool_init() { # <pool>
    ceph osd pool create "$1" >/dev/null && rbd pool init "$1"
}
step_rbd() {
    echo "Creating RBD pool ${CEPH_RBD_POOL}..."
    wait_for "RBD pool ${CEPH_RBD_POOL}" rbd_pool_init "$CEPH_RBD_POOL"
    echo "RBD pool ${CEPH_RBD_POOL} initialized."
    mark_ready rbd
}

# --- Create a CephFS filesystem ---
# `ceph fs volume create` only creates the pools and the fs here ("no MDS
# daemons created"); the standby mds.demo started above takes it over.
mgr_commands_ready() { # the mgr is active and has registered its module commands
    ceph mgr stat | grep -q '"available": *true' && ceph fs volume ls >/dev/null
}
# `fs volume create` creates the fs, then asks the orchestrator for MDS
# daemons. With the test_orchestrator backend active (the orchestrator step,
# or a persisted cluster that had it) that request fails, so the command
# errors although the fs exists: an existing fs counts as created.
fs_create() { # <fs name>
    ceph fs get "$1" >/dev/null 2>&1 || ceph fs volume create "$1"
}
fs_active() { # <fs name>
    ceph fs status "$1" | grep -q active
}
step_cephfs() {
    # `fs volume create` belongs to the mgr's volumes module: the mon only
    # accepts it once the active mgr has registered its module commands, which
    # lags the mgr becoming available. Run it too early - as a slow CI runner
    # does - and the mon answers "no valid command found" / EINVAL.
    echo "Waiting for mgr module commands..."
    wait_for "mgr module commands" mgr_commands_ready
    echo "Creating CephFS ${CEPH_CEPHFS_NAME}..."
    wait_for "CephFS ${CEPH_CEPHFS_NAME} created" fs_create "$CEPH_CEPHFS_NAME"
    wait_for "CephFS ${CEPH_CEPHFS_NAME} active" fs_active "$CEPH_CEPHFS_NAME"
    echo "CephFS ${CEPH_CEPHFS_NAME} active."
    mark_ready cephfs
}

# --- RGW, then the S3 demo user and the seed data ---
# Answering HTTP on :8080 means RGW finished its own setup (pools, zone). The
# user and seed come after it, so radosgw-admin does not race RGW's setup.
rgw_up() {
    curl -s -o /dev/null http://127.0.0.1:8080
}
# On a persisted cluster the user already exists from an earlier start; its
# key is (re)applied so changed CEPH_DEMO_ACCESS_KEY/SECRET_KEY take effect.
s3_user() { # <uid> <access key> <secret key>
    if ! radosgw-admin user info --uid="$1" >/dev/null 2>&1; then
        radosgw-admin user create --uid="$1" --display-name="Ceph demo user" \
            --access-key="$2" --secret-key="$3" >/dev/null || return
    else
        radosgw-admin key create --uid="$1" --key-type=s3 \
            --access-key="$2" --secret-key="$3" >/dev/null || return
    fi
    radosgw-admin caps add --caps="buckets=*;users=*;usage=*;metadata=*" --uid="$1" >/dev/null
}
# radosgw-admin cannot write objects and the image ships no S3 client, so the
# seed objects go in over the S3 API with a v2 signature (python3 + curl, both
# already present; v21+ images ship no openssl CLI). Uses the demo user,
# creating it if it does not exist yet.
seed_user() { # <uid>
    radosgw-admin user info --uid="$1" >/dev/null 2>&1 \
        || radosgw-admin user create --uid="$1" --display-name="Ceph demo user" >/dev/null
}
s3_put() { # <access key> <secret key> <path> <content-type> [curl args...]
    local access=$1 secret=$2 path=$3 ctype=$4 now sig
    shift 4
    now=$(date -R -u)
    sig=$(printf '%s\n\n%s\n%s\n%s' PUT "$ctype" "$now" "$path" \
        | S3_SECRET="$secret" python3 -c 'import base64,hashlib,hmac,os,sys
print(base64.b64encode(hmac.new(os.environ["S3_SECRET"].encode(),
    sys.stdin.buffer.read(), hashlib.sha1).digest()).decode())')
    curl -sSf -o /dev/null -X PUT -H "Date: ${now}" -H "Content-Type: ${ctype}" \
        -H "Authorization: AWS ${access}:${sig}" "$@" \
        "http://127.0.0.1:8080${path}"
}
seed_objects() { # <access key> <secret key> <bucket> <count>
    local i
    s3_put "$1" "$2" "/$3" "" || return
    for i in $(seq 1 "$4"); do
        printf 'ceph-test seed object %s\n' "$i" \
            | s3_put "$1" "$2" "/$3/seed-${i}.txt" text/plain --data-binary @- || return
    done
}
bucket_has_objects() { # <bucket>
    radosgw-admin bucket stats --bucket="$1" | grep -q '"num_objects": [1-9]'
}
step_rgw() {
    local keys
    wait_for "RGW HTTP" rgw_up
    echo "RGW ready."
    mark_ready rgw

    if is_true "$S3_USER"; then
        echo "Creating S3 demo user..."
        wait_for "S3 user ${CEPH_DEMO_UID}" s3_user "$CEPH_DEMO_UID" \
            "$CEPH_DEMO_ACCESS_KEY" "$CEPH_DEMO_SECRET_KEY"
        echo "S3 user created."
        mark_ready s3-user
    fi

    if is_true "$CEPH_RGW_SEED"; then
        echo "Seeding RGW (user ${CEPH_DEMO_UID}, bucket ${CEPH_RGW_SEED_BUCKET})..."
        wait_for "seed user ${CEPH_DEMO_UID}" seed_user "$CEPH_DEMO_UID"
        keys=$(timeout 60 radosgw-admin user info --uid="$CEPH_DEMO_UID" --format=json 2>/dev/null \
            | python3 -c 'import json,sys; k=json.load(sys.stdin)["keys"][0]; print(k["access_key"], k["secret_key"])')
        wait_for "RGW seed objects" seed_objects "${keys% *}" "${keys#* }" \
            "$CEPH_RGW_SEED_BUCKET" "$CEPH_RGW_SEED_OBJECTS"
        wait_for "RGW seed bucket stats" bucket_has_objects "$CEPH_RGW_SEED_BUCKET"
        echo "RGW seeded: ${CEPH_RGW_SEED_OBJECTS} objects in ${CEPH_RGW_SEED_BUCKET}."
        mark_ready rgw-seed
    fi
}

# --- Test orchestrator backend ---
# Ceph's test_orchestrator module provides a fake orchestrator so dashboard
# pages that require one (Hosts, Services, Physical Disks, cluster expansion,
# multi-cluster onboarding) work. Data is synthetic and actions are no-ops.
# Its data replaces the module's guesses (host "localhost", status unknown, no
# RGW, failing "orch device ls") with data the orch commands return as-is:
# CEPH_TEST_ORCHESTRATOR_DATA (a file path or inline JSON) if set, otherwise
# generated from the daemons running here (orch_data.py). The module keeps
# load_data data only in memory and the mgr respawns when the set of enabled
# modules changes, so the image patches it to read $ORCH_DATA when it starts
# (patch_test_orchestrator.py); load_data here is for the mgr already running.
orch_backend() {
    # "orch set backend" only sticks once the module is active, so set it
    # until the backend reports ready.
    ceph orch set backend test_orchestrator >/dev/null 2>&1 || true
    ceph orch status | grep -q "Available: Yes"
}
ORCH_DATA=/var/run/ceph/orch_data.json
orch_data_write() {
    if [ -z "$CEPH_TEST_ORCHESTRATOR_DATA" ]; then
        ORCH_HOST=$(hostname) ORCH_IP=$ACTUAL_IP CEPH_CEPHFS_NAME=$CEPH_CEPHFS_NAME \
            CEPH_DEVICE_CLASS=$CEPH_DEVICE_CLASS CEPH_DASHBOARD=$CEPH_DASHBOARD \
            CEPH_DASHBOARD_PORT=$CEPH_DASHBOARD_PORT CEPH_PROMETHEUS=$CEPH_PROMETHEUS \
            CEPH_TEST_ORCHESTRATOR_IMAGE=$CEPH_TEST_ORCHESTRATOR_IMAGE \
            CEPH_TEST_ORCHESTRATOR_IMAGE_ID=$CEPH_TEST_ORCHESTRATOR_IMAGE_ID \
            python3 /opt/ceph-fast/orch_data.py > "$ORCH_DATA"
    elif [ -f "$CEPH_TEST_ORCHESTRATOR_DATA" ]; then
        cp "$CEPH_TEST_ORCHESTRATOR_DATA" "$ORCH_DATA"
    else
        printf '%s' "$CEPH_TEST_ORCHESTRATOR_DATA" > "$ORCH_DATA"
    fi
}
step_orchestrator() {
    echo "Enabling test_orchestrator backend..."
    wait_for "test_orchestrator backend" orch_backend
    echo "test_orchestrator backend active."

    if [ -n "$CEPH_TEST_ORCHESTRATOR_DATA" ]; then
        echo "Loading test_orchestrator data from CEPH_TEST_ORCHESTRATOR_DATA..."
    else
        echo "Loading test_orchestrator data generated from running daemons..."
    fi
    # Not silenced: a bad user-supplied file must fail the container loudly,
    # generated data is best-effort.
    if ! { orch_data_write && timeout 60 ceph test_orchestrator load_data -i "$ORCH_DATA" >/dev/null; }; then
        if [ -n "$CEPH_TEST_ORCHESTRATOR_DATA" ]; then
            echo "FAILED: could not load CEPH_TEST_ORCHESTRATOR_DATA" >&2
            fail
        fi
        echo "WARNING: could not load generated test_orchestrator data" >&2
    fi
    mark_ready orchestrator
}

# --- Prometheus exporter (mgr module, enabled before the mgr started) ---
# Exports Ceph metrics on :9283 for an external Prometheus to scrape. This is
# the data source behind the dashboard's embedded Grafana graphs.
mgr_service_url() { # <module>: the URL the mgr module serves on
    timeout 60 ceph mgr services | grep -o "\"$1\": *\"[^\"]*" | grep -o 'http[s]*://.*'
}
step_prometheus() {
    echo "Enabling Prometheus mgr module (exporter on :9283)..."
    wait_for "prometheus exporter" mgr_service_url prometheus
    echo "Prometheus exporter available at: $(mgr_service_url prometheus)"
    mark_ready prometheus
}

# --- Ceph dashboard (mgr module, enabled and configured before the mgr started) ---
dashboard_user() { # <user> <password>
    printf '%s' "$2" > /tmp/dashboard_pw
    ceph dashboard ac-user-create "$1" -i /tmp/dashboard_pw administrator >/dev/null 2>&1 \
        || ceph dashboard ac-user-set-password "$1" -i /tmp/dashboard_pw >/dev/null
    local rc=$?
    rm -f /tmp/dashboard_pw
    return $rc
}
step_dashboard() {
    echo "Enabling Ceph dashboard on port ${CEPH_DASHBOARD_PORT}..."
    # The mgr registers the dashboard's "ceph dashboard" sub-commands only
    # after it finishes loading the module, so gate on one of them: once
    # set-pwd-policy-enabled succeeds, everything below is safe. Disabling the
    # policy also lets weak test passwords (e.g. "admin") through.
    wait_for "dashboard commands" ceph dashboard set-pwd-policy-enabled false

    wait_for "dashboard user ${CEPH_DASHBOARD_USER}" dashboard_user \
        "$CEPH_DASHBOARD_USER" "$CEPH_DASHBOARD_PASSWORD"

    # Point the dashboard at Prometheus so its monitoring/alerts pages and
    # native charts (query_range) work. This is the mgr-facing URL; the backend
    # proxies these queries, the browser does not reach Prometheus directly.
    if [ -n "$CEPH_PROMETHEUS_API_URL" ]; then
        echo "Configuring Prometheus API host (${CEPH_PROMETHEUS_API_URL})..."
        wait_for "prometheus api host" ceph dashboard set-prometheus-api-host "$CEPH_PROMETHEUS_API_URL"
        wait_for "prometheus api ssl" ceph dashboard set-prometheus-api-ssl-verify false
    fi

    # Point the dashboard at Alertmanager so its alerts/silences pages work.
    if [ -n "$CEPH_ALERTMANAGER_API_URL" ]; then
        echo "Configuring Alertmanager API host (${CEPH_ALERTMANAGER_API_URL})..."
        wait_for "alertmanager api host" ceph dashboard set-alertmanager-api-host "$CEPH_ALERTMANAGER_API_URL"
        wait_for "alertmanager api ssl" ceph dashboard set-alertmanager-api-ssl-verify false
    fi

    # Point the dashboard at an external Grafana for the embedded graphs.
    # Requires a Grafana + Prometheus stack (see compose/).
    if [ -n "$CEPH_GRAFANA_API_URL" ]; then
        echo "Configuring Grafana embedding (api-url: ${CEPH_GRAFANA_API_URL})..."
        wait_for "grafana api url" ceph dashboard set-grafana-api-url "$CEPH_GRAFANA_API_URL"
        # Test setup uses plain HTTP / self-signed certs, so skip verification.
        wait_for "grafana api ssl" ceph dashboard set-grafana-api-ssl-verify false
        # URL the browser uses for the iframe; falls back to the api-url.
        wait_for "grafana frontend url" ceph dashboard set-grafana-frontend-api-url \
            "${CEPH_GRAFANA_FRONTEND_API_URL:-$CEPH_GRAFANA_API_URL}"
    fi

    wait_for "dashboard URL" mgr_service_url dashboard
    echo "Dashboard available at: $(mgr_service_url dashboard) (login: ${CEPH_DASHBOARD_USER})"
    mark_ready dashboard
}

declare -A STEPS # pid -> step name
start_step() { # <name> <function>
    "$2" &
    STEPS[$!]=$1
}
echo "Waiting for cluster..."
start_step base step_base
if is_true "$CEPH_RGW"; then start_step rgw step_rgw; fi
if [ -n "$CEPH_DEVICE_CLASS" ]; then start_step device-class step_device_class; fi
if [ -n "$CEPH_RBD_POOL" ]; then start_step rbd step_rbd; fi
if is_true "$CEPH_CEPHFS"; then start_step cephfs step_cephfs; fi
if is_true "$CEPH_TEST_ORCHESTRATOR"; then start_step orchestrator step_orchestrator; fi
if is_true "$CEPH_PROMETHEUS"; then start_step prometheus step_prometheus; fi
if is_true "$CEPH_DASHBOARD"; then start_step dashboard step_dashboard; fi

# --- Supervise ---
# A daemon exiting, or a setup step failing, stops the container. Once every
# step is done, stream the cluster log as before; ceph -w is restarted if it
# exits.
while true; do
    pid=
    if wait -n -p pid; then status=0; else status=$?; fi
    [ -n "$pid" ] || continue
    if [ -n "${DAEMONS[$pid]:-}" ]; then
        daemon_exited "$pid" "$status"
    elif [ -n "${STEPS[$pid]:-}" ]; then
        step=${STEPS[$pid]}
        unset "STEPS[$pid]"
        if [ "$status" != 0 ]; then
            # A daemon exit makes the step fail too and is the better reason;
            # give its exit a moment to be collected.
            sleep 0.5
            check_daemons
            echo "FAILED: setup step ${step} failed" >&2
            fail
        fi
        if [ ${#STEPS[@]} -eq 0 ]; then
            echo "=== ceph-test setup complete ==="
            mark_ready all
            ceph -w &
            WATCH_PID=$!
        fi
    elif [ "$pid" = "$WATCH_PID" ]; then
        sleep 1
        ceph -w &
        WATCH_PID=$!
    fi
done
