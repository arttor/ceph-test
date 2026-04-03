#!/bin/bash
# Runs at Docker build time. Pre-bakes the entire Ceph cluster so that
# the runtime entrypoint only needs to patch MON_IP and start daemons.
set -e

FSID=$(python3 -c "import uuid; print(uuid.uuid4())")

cat > /etc/ceph/ceph.conf <<EOF
[global]
fsid = $FSID
mon initial members = demo
mon host = v2:127.0.0.1:3300/0
osd crush chooseleaf type = 0
osd pool default size = 1
osd pool default min size = 1
osd pool default pg num = 8
osd pool default pgp num = 8
public network = 0.0.0.0/0
cluster network = 0.0.0.0/0
osd objectstore = bluestore
ms bind msgr2 = true
auth cluster required = cephx
auth service required = cephx
auth client required = cephx
mon allow pool delete = true
mon max pg per osd = 500
bluestore_block_size = 2147483648
osd_memory_target = 939524096
osd_scrub_auto_repair = false
osd_scrub_begin_hour = 0
osd_scrub_end_hour = 0
bluestore_cache_size_hdd = 67108864
bluestore_cache_size_ssd = 67108864
debug_osd = 0/0
debug_bluestore = 0/0
debug_rocksdb = 0/0
debug_ms = 0/0

[osd.0]
osd data = /var/lib/ceph/osd/ceph-0

[client.rgw.demo]
rgw dns name = demo
rgw frontends = beast endpoint=0.0.0.0:8080
keyring = /var/lib/ceph/radosgw/ceph-rgw.demo/keyring
EOF

# --- keyrings ---
ceph-authtool /etc/ceph/ceph.client.admin.keyring \
    --create-keyring --gen-key -n client.admin \
    --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
ceph-authtool /etc/ceph/ceph.mon.keyring \
    --create-keyring --gen-key -n mon. --cap mon 'allow *'
ceph-authtool /etc/ceph/ceph.mon.keyring \
    --import-keyring /etc/ceph/ceph.client.admin.keyring

# --- monmap ---
monmaptool --create --add demo 127.0.0.1:3300 --fsid "$FSID" /etc/ceph/monmap
chown -R ceph: /etc/ceph

# --- mon mkfs ---
ceph-mon --cluster ceph --mkfs -i demo \
    --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring
chown -R ceph: /var/lib/ceph/mon/ceph-demo
touch /var/lib/ceph/mon/ceph-demo/done

# --- start mon temporarily for auth + osd bootstrap ---
ceph-mon --cluster ceph -i demo --public-addr 127.0.0.1:3300 --setuser ceph --setgroup ceph &
MON_PID=$!
sleep 3

# --- mgr keyring ---
ceph auth get-or-create mgr.demo mon 'allow profile mgr' mds 'allow *' osd 'allow *' \
    -o /var/lib/ceph/mgr/ceph-demo/keyring
chown -R ceph: /var/lib/ceph/mgr/ceph-demo

# --- osd keyring + mkfs ---
ceph auth get-or-create osd.0 mon 'allow profile osd' osd 'allow *' mgr 'allow profile osd' \
    -o /var/lib/ceph/osd/ceph-0/keyring
chown -R ceph: /var/lib/ceph/osd/ceph-0
ceph-osd --conf /etc/ceph/ceph.conf --osd-data /var/lib/ceph/osd/ceph-0 --mkfs -i 0
echo "bluestore" > /var/lib/ceph/osd/ceph-0/type
chown -R ceph: /var/lib/ceph/osd/ceph-0

# --- rgw keyring ---
ceph auth get-or-create client.rgw.demo mon 'allow rw' osd 'allow rwx' \
    -o /var/lib/ceph/radosgw/ceph-rgw.demo/keyring
chown -R ceph: /var/lib/ceph/radosgw/ceph-rgw.demo

# --- cluster config ---
ceph config set mon auth_allow_insecure_global_id_reclaim false
ceph config set global osd_pool_default_pg_autoscale_mode off

# --- stop temp mon ---
kill $MON_PID && wait $MON_PID || true

# --- save for entrypoint (survives volume mount over /etc/ceph) ---
echo "$FSID" > /opt/ceph-fast/fsid
mkdir -p /opt/ceph-fast/keyring-backup
cp /etc/ceph/ceph.conf       /opt/ceph-fast/ceph.conf.baked
cp /etc/ceph/ceph.client.admin.keyring /opt/ceph-fast/keyring-backup/
cp /etc/ceph/ceph.mon.keyring          /opt/ceph-fast/keyring-backup/
cp /etc/ceph/monmap                    /opt/ceph-fast/keyring-backup/

echo "Bootstrap complete."
