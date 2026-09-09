ARG CEPH_VERSION=v19
FROM quay.io/ceph/ceph:${CEPH_VERSION}

RUN mkdir -p \
    /var/lib/ceph/mon/ceph-demo \
    /var/lib/ceph/mgr/ceph-demo \
    /var/lib/ceph/osd/ceph-0 \
    /var/lib/ceph/radosgw/ceph-rgw.demo \
    /var/lib/ceph/mds/ceph-demo \
    /var/run/ceph \
    /etc/ceph \
    /opt/ceph-fast

# Bake fsid-independent keyrings + a ceph.conf template. The mkfs happens at
# container start (entrypoint.sh), so each container gets its own fsid.
COPY bootstrap.sh /opt/ceph-fast/bootstrap.sh
RUN chmod +x /opt/ceph-fast/bootstrap.sh && /opt/ceph-fast/bootstrap.sh

COPY entrypoint.sh /opt/ceph-fast/entrypoint.sh
RUN chmod +x /opt/ceph-fast/entrypoint.sh

EXPOSE 3300 6789 8080 8443 9283

ENTRYPOINT ["/opt/ceph-fast/entrypoint.sh"]
