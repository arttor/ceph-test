#!/usr/bin/env python3
"""Build time: make test_orchestrator load the entrypoint's data file on start.

The module keeps "load_data" data only in memory, and the mgr respawns
itself whenever a mgr module is enabled or disabled. Without this patch the
new mgr serves the module's guesses (host "localhost", ...) until the data
is loaded again. Patched, it reads ORCH_DATA in its constructor, so it is
right as soon as the orchestrator is available.

Fails the build if the upstream code no longer matches.
"""
import sys

MODULE = "/usr/share/ceph/mgr/test_orchestrator/module.py"
ORCH_DATA = "/var/run/ceph/orch_data.json"  # written by entrypoint.sh

OLD = "        self._init_data({})\n"
NEW = f"""        # ceph-test: start with the data the entrypoint wrote (see
        # /opt/ceph-fast/patch_test_orchestrator.py).
        try:
            with open({ORCH_DATA!r}) as f:
                self._init_data(json.load(f))
        except FileNotFoundError:
            self._init_data({{}})
        except Exception as e:
            self.log.error('ceph-test: cannot load {ORCH_DATA}: %s', e)
            self._init_data({{}})
"""

src = open(MODULE).read()
if src.count(OLD) != 1 or "\nimport json\n" not in src:
    sys.exit(f"{MODULE}: unexpected upstream code, patch_test_orchestrator.py needs an update")
open(MODULE, "w").write(src.replace(OLD, NEW))
print(f"patched {MODULE}")
