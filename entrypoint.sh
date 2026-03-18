#!/bin/bash
set -e

: "${MON_IP:=0.0.0.0}"
: "${CEPH_PUBLIC_NETWORK:=0.0.0.0/0}"
: "${CEPH_DEMO_UID:=demo}"
: "${CEPH_DEMO_ACCESS_KEY:=}"
: "${CEPH_DEMO_SECRET_KEY:=}"

FSID=$(cat /opt/ceph-fast/fsid)

if [ "$MON_IP" = "0.0.0.0" ]; then
    ACTUAL_IP=$(hostname -i | awk '{print $1}')
else
    ACTUAL_IP=$MON_IP
fi

echo "=== ceph-test starting ==="
echo "MON_IP=$ACTUAL_IP  NETWORK=$CEPH_PUBLIC_NETWORK"

# --- Restore keyrings if /etc/ceph is an empty volume mount ---
if [ ! -f /etc/ceph/ceph.client.admin.keyring ]; then
    echo "Volume mount detected - restoring keyrings..."
    cp /opt/ceph-fast/keyring-backup/* /etc/ceph/
    cp /opt/ceph-fast/ceph.conf.baked /etc/ceph/ceph.conf
    chown -R ceph: /etc/ceph
fi

# --- Patch ceph.conf with real IP ---
sed -i "s|mon host = v2:127.0.0.1:3300/0|mon host = v2:${ACTUAL_IP}:3300/0|" /etc/ceph/ceph.conf
sed -i "s|public network = 0.0.0.0/0|public network = ${CEPH_PUBLIC_NETWORK}|" /etc/ceph/ceph.conf

# --- Append extra config if provided (e.g. Keystone RGW settings) ---
if [ -n "$CEPH_EXTRA_CONF" ]; then
    echo "$CEPH_EXTRA_CONF" >> /etc/ceph/ceph.conf
fi
if ls /etc/ceph/ceph.conf.d/*.conf 1>/dev/null 2>&1; then
    for f in /etc/ceph/ceph.conf.d/*.conf; do
        cat "$f" >> /etc/ceph/ceph.conf
    done
fi

# --- Inject updated monmap into mon store ---
MONMAP_TMP=/tmp/monmap_new
rm -f "$MONMAP_TMP"
monmaptool --create --add demo "${ACTUAL_IP}:3300" --fsid "$FSID" "$MONMAP_TMP"
ceph-mon -i demo --inject-monmap "$MONMAP_TMP"
cp "$MONMAP_TMP" /etc/ceph/monmap
chown ceph: /etc/ceph/monmap
rm -f "$MONMAP_TMP"

# --- Start daemons ---
echo "Starting mon..."
ceph-mon --cluster ceph -i demo --public-addr "${ACTUAL_IP}:3300" --setuser ceph --setgroup ceph &

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

echo "=== ceph-test ready ==="

exec ceph -w
