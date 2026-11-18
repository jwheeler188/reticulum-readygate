#!/usr/bin/env python3
"""
rns-failover - priority failover between Reticulum uplink interfaces.

Reticulum has no "backup interface" setting: every attached interface carries
your announces and path requests, and receives every announce the far side
floods. Linking one node to several hubs that are already bridged to each
other (for example your own gateway <-> hub A <-> hub B) multiplies that
traffic and makes the node prefer whichever hub is one hop closer instead of
your own gateway.

This watchdog keeps ONLY the best working uplink attached, using rnsd's live
interface management (rnstatus --attach / --detach, RNS >= 1.5.6), so rnsd
and the apps using it are never restarted.

  tiers      interface names (the [[section]] names in the Reticulum config),
             highest priority first.
  failover   when no attached tier has been online for --grace seconds,
             attach the next tier down (higher tiers stay attached so they
             can reconnect on their own; a disconnected TCP client sends
             nothing, so this causes no duplication).
  failback   when a higher tier has been online for --hold seconds, detach
             every tier below it.

Interfaces not listed as tiers (AutoInterface, RNode, ...) are never touched.
"""
import argparse
import json
import subprocess
import sys
import time


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


class Failover:
    def __init__(self, a):
        self.a = a
        self.tiers = a.tiers
        self.online_since = {t: None for t in self.tiers}
        self.all_down_since = None

    def rnstatus(self, *args):
        cmd = [self.a.rnstatus] + (["--config", self.a.config] if self.a.config else []) + list(args)
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    def status(self):
        r = self.rnstatus("-j")
        # rnstatus may print RNS log lines before the JSON, so start at the
        # first line that opens the JSON object.
        start = next((i for i, l in enumerate(r.stdout.splitlines()) if l.startswith("{")), None)
        if r.returncode != 0 or start is None:
            return None
        data = json.loads("\n".join(r.stdout.splitlines()[start:]))
        return {i.get("short_name"): bool(i.get("status")) for i in data.get("interfaces", [])}

    def attach(self, name):
        r = self.rnstatus("--attach", name)
        log(f"attach  {name}: {(r.stdout or r.stderr).strip()}")

    def detach(self, name):
        r = self.rnstatus("--detach", name)
        log(f"detach  {name}: {(r.stdout or r.stderr).strip()}")

    def step(self):
        st = self.status()
        if st is None:
            log("rnsd shared instance not reachable; waiting")
            return
        now = time.time()
        attached = [t for t in self.tiers if t in st]
        for t in self.tiers:
            if st.get(t):
                self.online_since[t] = self.online_since[t] or now
            else:
                self.online_since[t] = None

        # Highest-priority tier that is online right now.
        best = next((i for i, t in enumerate(self.tiers) if st.get(t)), None)

        if best is not None:
            self.all_down_since = None
            # keep everything above best attached so it can reconnect by itself
            for t in self.tiers[:best]:
                if t not in st:
                    self.attach(t)
            # drop everything below best once best has been stable for --hold
            if now - self.online_since[self.tiers[best]] >= self.a.hold:
                for t in self.tiers[best + 1:]:
                    if t in st:
                        log(f"{self.tiers[best]} is up; failing back")
                        self.detach(t)
            return

        # Nothing online.
        if not attached:
            self.attach(self.tiers[0])
            self.all_down_since = now
            return
        self.all_down_since = self.all_down_since or now
        lowest = max(self.tiers.index(t) for t in attached)
        for t in self.tiers[:lowest]:
            if t not in st:
                self.attach(t)
        if now - self.all_down_since >= self.a.grace and lowest + 1 < len(self.tiers):
            log(f"no uplink online for {int(now - self.all_down_since)}s; failing over")
            self.attach(self.tiers[lowest + 1])
            self.all_down_since = now

    def run(self):
        log("tiers: " + "  >  ".join(self.tiers))
        while True:
            try:
                self.step()
            except Exception as e:
                log(f"error: {e}")
            if self.a.once:
                break
            time.sleep(self.a.interval)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tier", dest="tiers", action="append", required=True,
                   help="interface name, repeat in priority order")
    p.add_argument("--rnstatus", default="rnstatus")
    p.add_argument("--config", default=None, help="Reticulum config dir")
    p.add_argument("--interval", type=float, default=15)
    p.add_argument("--grace", type=float, default=30, help="seconds all-down before failing over")
    p.add_argument("--hold", type=float, default=20, help="seconds a higher tier must be up before failing back")
    p.add_argument("--once", action="store_true")
    a = p.parse_args()
    Failover(a).run()


if __name__ == "__main__":
    sys.exit(main())
