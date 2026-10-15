ARG CEPH_VERSION=v19
FROM quay.io/ceph/ceph:${CEPH_VERSION}
ARG CEPH_VERSION

# Image name the test orchestrator reports for the daemons (orch_data.py).
ENV CEPH_TEST_ORCHESTRATOR_IMAGE=quay.io/ceph/ceph:${CEPH_VERSION}

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

COPY entrypoint.sh ceph-test-health orch_data.py patch_test_orchestrator.py /opt/ceph-fast/
RUN chmod +x /opt/ceph-fast/entrypoint.sh /opt/ceph-fast/ceph-test-health \
    && ln -s /opt/ceph-fast/ceph-test-health /usr/local/bin/ceph-test-health \
    && python3 /opt/ceph-fast/patch_test_orchestrator.py

# Healthy once mon, mgr and osd are up: the "=== ceph-test ready ===" line.
# The check only reads a marker file, so it is cheap enough to poll every
# second while starting. The start period covers a slow machine: failures in
# it do not count, and the entrypoint itself fails the container on timeout.
HEALTHCHECK --interval=5s --timeout=10s --start-period=10m --start-interval=1s --retries=3 \
    CMD ["ceph-test-health"]

EXPOSE 3300 6789 8080 8443 9283

ENTRYPOINT ["/opt/ceph-fast/entrypoint.sh"]
