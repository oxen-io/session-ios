#!/usr/bin/env python3

import os
import subprocess
import shutil
import time
import json

os.chdir(os.path.dirname(os.path.abspath(__file__)))

subprocess.run(["xcrun", "simctl", "delete", "unavailable"], check=True)

simctl_list = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "-je"], check=True, stdout=subprocess.PIPE).stdout)

now = time.time()

for rt, devs in simctl_list.get("devices", {}).items():
    for dev in devs:
        udid = dev["udid"]
        nuke_it = False
        if os.path.isfile(udid):
            if os.path.getmtime(udid) <= now:
                nuke_it = True
                os.remove(udid)
            # else the keepalive file is still active
        elif os.path.getmtime(dev["dataPath"]) <= now - 3600:
            # no keep-alive and more than an hour old so kill it
            nuke_it = True

        if nuke_it:
            subprocess.run(["xcrun", "simctl", "delete", udid])
            if os.path.exists(dev["logPath"]):
                shutil.rmtree(dev["logPath"])
