#!/bin/bash
# Build time: generate the fsid-independent keyrings and a ceph.conf template.
# The mkfs (mon + osd) happens at container start, see entrypoint.sh, so each
# container gets its own fsid unless CEPH_FSID is set.
set -e

cat > /etc/ceph/ceph.conf <<'EOF'
[global]
fsid = 00000000-0000-0000-0000-000000000000
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

# --- keyrings (independent of fsid, so safe to bake) ---
ceph-authtool /etc/ceph/ceph.client.admin.keyring \
    --create-keyring --gen-key -n client.admin \
    --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
ceph-authtool /etc/ceph/ceph.mon.keyring \
    --create-keyring --gen-key -n mon. --cap mon 'allow *'
ceph-authtool /etc/ceph/ceph.mon.keyring \
    --import-keyring /etc/ceph/ceph.client.admin.keyring
chown -R ceph: /etc/ceph

# --- backup so the entrypoint can restore into an empty /etc/ceph volume ---
mkdir -p /opt/ceph-fast/keyring-backup
cp /etc/ceph/ceph.conf                 /opt/ceph-fast/ceph.conf.baked
cp /etc/ceph/ceph.client.admin.keyring /opt/ceph-fast/keyring-backup/
cp /etc/ceph/ceph.mon.keyring          /opt/ceph-fast/keyring-backup/

echo "Key/conf preparation complete."
