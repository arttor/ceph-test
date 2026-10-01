#!/usr/bin/env python3
"""Print test_orchestrator data (for "ceph test_orchestrator load_data")
describing the daemons actually running in this container.

Without it the test_orchestrator guesses from `ps aux`: host "localhost",
every daemon in status "unknown", no versions, no RGW (its process is
"radosgw", not "ceph-rgw"), and `orch device ls` fails because
ceph-volume finds no disk.

Only DaemonDescription fields that exist since v19 are used: the module
passes every key straight to the constructor, so an unknown one fails.

Input comes from the environment (set by entrypoint.sh): ORCH_HOST,
ORCH_IP, CEPH_CEPHFS_NAME, CEPH_DEVICE_CLASS, the dashboard/prometheus
toggles and CEPH_TEST_ORCHESTRATOR_IMAGE[_ID].
"""
import datetime
import json
import os
import re
import subprocess

env = os.environ
host = env["ORCH_HOST"]
ip = env["ORCH_IP"]
now = datetime.datetime.now(datetime.timezone.utc)
BLOCK = "/var/lib/ceph/osd/ceph-0/block"  # the OSD's backing file


def ts(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def enabled(name):
    return env.get(name, "false") in ("true", "1")


# "ceph version 21.1.1 (<sha>) umbrella (dev)" -> "21.1.1"
version = subprocess.check_output(["ceph", "--version"], text=True).split()[2]

# A container cannot see its own image id, so that one only comes from
# outside; docker reports "sha256:<hex>", cephadm (podman) the bare hex.
image = {}
if env.get("CEPH_TEST_ORCHESTRATOR_IMAGE"):
    image["container_image_name"] = env["CEPH_TEST_ORCHESTRATOR_IMAGE"]
if env.get("CEPH_TEST_ORCHESTRATOR_IMAGE_ID"):
    image["container_image_id"] = env["CEPH_TEST_ORCHESTRATOR_IMAGE_ID"].removeprefix("sha256:")

# Ports the daemons in this image actually listen on (see EXPOSE).
mgr_ports = []
if enabled("CEPH_DASHBOARD"):
    mgr_ports.append(int(env.get("CEPH_DASHBOARD_PORT", "8443")))
if enabled("CEPH_PROMETHEUS"):
    mgr_ports.append(9283)
ports = {"mgr": mgr_ports, "rgw": [8080]}

# daemon type -> service name, as cephadm would name it
fs_name = env.get("CEPH_CEPHFS_NAME", "cephfs")
service_of = {"mon": "mon", "mgr": "mgr", "osd": "osd",
              "mds": f"mds.{fs_name}", "rgw": "rgw.demo"}

daemon_re = re.compile(
    r"^(?:\S*/)?(?:ceph-(?P<type>mon|mgr|osd|mds)\s.*?-i\s(?P<id>\S+)"
    r"|radosgw\s.*?-n\sclient\.rgw\.(?P<rgw_id>\S+))")

daemons = []
ps = subprocess.check_output(["ps", "-eo", "etimes=,rss=,args="], text=True)
for line in ps.splitlines():
    etimes, rss, args = line.split(None, 2)
    m = daemon_re.match(args)
    if not m:
        continue
    dtype = m.group("type") or "rgw"
    did = m.group("id") or m.group("rgw_id")
    started = now - datetime.timedelta(seconds=int(etimes))
    d = {
        "daemon_type": dtype,
        "daemon_id": did,
        "hostname": host,
        "ip": ip,
        "service_name": service_of[dtype],
        "status": 1,
        "status_desc": "running",
        "version": version,
        "created": ts(started),
        "started": ts(started),
        "last_refresh": ts(now),
        "memory_usage": int(rss) * 1024,
        "is_active": dtype == "mgr",
        **image,
    }
    if ports.get(dtype):
        d["ports"] = ports[dtype]
    daemons.append(d)

services = []
for name in sorted({d["service_name"] for d in daemons}):
    members = [d for d in daemons if d["service_name"] == name]
    stype, _, sid = name.partition(".")
    svc = {
        "service_type": stype,
        "placement": {"hosts": [host]},
        "status": {
            "size": len(members),
            "running": len(members),
            "created": min(d["created"] for d in members),
            "last_refresh": ts(now),
            **image,
        },
    }
    if sid:
        svc["service_id"] = sid
    if stype == "rgw":
        svc["spec"] = {"rgw_frontend_port": 8080}
    if stype == "osd":
        # An OSD spec does not validate without data_devices.
        svc["unmanaged"] = True
        svc["spec"] = {"data_devices": {"paths": [BLOCK]}}
    services.append(svc)

# The OSD's backing file, reported like a disk ceph-volume already consumed.
devices = []
if os.path.exists(BLOCK):
    size = os.path.getsize(BLOCK)
    dclass = env.get("CEPH_DEVICE_CLASS") or "hdd"
    devices.append({
        "path": BLOCK,
        "available": False,
        "rejected_reasons": ["Has BlueStore device label"],
        "device_id": "ceph-test-osd-0",
        "crush_device_class": env.get("CEPH_DEVICE_CLASS") or None,
        "lvs": [],
        "sys_api": {
            "size": size,
            "human_readable_size": f"{size / 2**30:.2f} GB",
            "rotational": "0" if dclass in ("ssd", "nvme") else "1",
            "path": BLOCK,
        },
    })

print(json.dumps({
    "inventory": [{"name": host, "addr": ip, "devices": devices, "labels": []}],
    "services": services,
    "daemons": daemons,
}))
