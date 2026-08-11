#!/usr/bin/env python3
"""Prometheus metrics exporter for Logos Blockchain Node.

Polls the node's JSON HTTP API and Docker stats, exposing metrics
in Prometheus format on port 9100.
"""

import os
import re
import time
import threading
import logging
import shutil

import requests
import docker
import yaml
from prometheus_client import start_http_server, Gauge, Counter, Info

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("logos-exporter")

# ── Configuration ────────────────────────────────────────────────────
NODE_API_URL = os.environ.get("NODE_API_URL", "http://logos-node:8080")
CONTAINER_NAME = os.environ.get("CONTAINER_NAME", "logos-node")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "15"))
CONFIG_PATH = os.environ.get("CONFIG_PATH", "/app/user_config.yaml")
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9100"))

# ── Prometheus Metrics ───────────────────────────────────────────────

# Node availability
node_up = Gauge("logos_node_up", "Whether the node API is reachable (1=up, 0=down)")

# Consensus (/cryptarchia/info)
consensus_mode = Gauge("logos_node_consensus_mode", "Consensus mode (labeled)", ["mode"])
node_slot = Gauge("logos_node_slot", "Current consensus slot")
node_height = Gauge("logos_node_height", "Current blockchain height")

# Network (/network/info)
node_peers = Gauge("logos_node_peers", "Number of connected peers")
node_connections = Gauge("logos_node_connections", "Number of active connections")
node_pending_connections = Gauge("logos_node_pending_connections", "Number of pending connections")

# Wallet balance (/wallet/{key}/balance)
wallet_balance = Gauge("logos_node_wallet_balance", "Wallet balance", ["key"])

# Docker container stats
container_cpu = Gauge("logos_container_cpu_percent", "Container CPU usage percentage")
container_memory = Gauge("logos_container_memory_bytes", "Container memory usage in bytes")
container_memory_limit = Gauge("logos_container_memory_limit_bytes", "Container memory limit in bytes")
container_net_rx = Gauge("logos_container_network_rx_bytes", "Container network received bytes")
container_net_tx = Gauge("logos_container_network_tx_bytes", "Container network transmitted bytes")
container_running = Gauge("logos_container_running", "Whether the container is running (1=yes, 0=no)")

# Host system metrics
host_memory_total = Gauge("logos_host_memory_total_bytes", "Host total memory in bytes")
host_memory_used = Gauge("logos_host_memory_used_bytes", "Host used memory in bytes")
host_disk_usage = Gauge("logos_host_disk_usage_percent", "Host disk usage percentage")
host_load_1m = Gauge("logos_host_load_1m", "Host 1-minute load average")
host_load_5m = Gauge("logos_host_load_5m", "Host 5-minute load average")
host_load_15m = Gauge("logos_host_load_15m", "Host 15-minute load average")


# Passthrough constructor for the node's YAML tags (!Env, !Otlp, !Zk,
# !Ed25519, !Rolling, !MaxFiles ...). Without it, safe_load blows up on the
# first unknown tag and we fall through to a regex — which works but is
# fragile if the file gets reshaped. Same trick keys_io.py uses.
class _Tagged:
    __slots__ = ("tag", "value")
    def __init__(self, tag, value):
        self.tag, self.value = tag, value


def _tag_constructor(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return _Tagged(tag_suffix, loader.construct_scalar(node))
    if isinstance(node, yaml.MappingNode):
        return _Tagged(tag_suffix, loader.construct_mapping(node, deep=True))
    return _Tagged(tag_suffix, loader.construct_sequence(node, deep=True))


yaml.SafeLoader.add_multi_constructor("!", _tag_constructor)


def parse_wallet_keys(config_path):
    """Parse wallet.known_keys from user_config.yaml.

    Returns ONLY the keys under wallet.known_keys — not KMS key IDs, not the
    libp2p node_key, not signing key IDs from other sections. A naive
    regex-everything approach matched all 64-hex strings in the file and the
    API rejected the non-wallet ones with HTTP 400.
    """
    try:
        with open(config_path, "r") as f:
            config = yaml.safe_load(f)
        known_keys = (config.get("wallet") or {}).get("known_keys") or {}
        if known_keys:
            return list(known_keys.keys())
    except Exception:
        pass

    # Fallback: extract just the wallet.known_keys block from raw text.
    try:
        with open(config_path, "r") as f:
            content = f.read()
        m = re.search(
            r"^\s*known_keys:\s*\n((?:[ \t]+[a-f0-9]{64}:.*\n?)+)",
            content,
            re.MULTILINE,
        )
        if m:
            return re.findall(r"^[ \t]+([a-f0-9]{64}):", m.group(1), re.MULTILINE)
    except Exception:
        pass
    return []


def poll_node_api():
    """Poll node JSON API endpoints and update Prometheus metrics."""
    try:
        resp = requests.get(f"{NODE_API_URL}/cryptarchia/info", timeout=5)
        resp.raise_for_status()
        data = resp.json()

        node_up.set(1)

        # 0.2.1: scalar "state" inside "cryptarchia_info" (e.g. "Bootstrapping")
        # 0.2.0: "mode" is an enum object like {"Started": "Bootstrapping"}
        # 0.1.x: "mode" was a scalar string like "Bootstrapping"
        mode_field = data.get("cryptarchia_info", {}).get("state") or data.get(
            "mode", "Unknown"
        )
        if isinstance(mode_field, dict) and mode_field:
            mode = next(iter(mode_field.values()), "Unknown")
        else:
            mode = mode_field
        # Reset all mode labels, set the active one
        for m in ("Online", "Bootstrapping"):
            consensus_mode.labels(mode=m).set(1 if m == mode else 0)

        # 0.2.0: slot/height/tip/lib live under "cryptarchia_info"
        # 0.1.x: they were at the top level
        info = data.get("cryptarchia_info", data)
        slot = info.get("slot", 0)
        height = info.get("height", 0)
        node_slot.set(slot)
        node_height.set(height)

        log.debug("Polled node: mode=%s slot=%s height=%s", mode, slot, height)

    except Exception as e:
        log.debug("Node API unreachable: %s", e)
        node_up.set(0)
        return  # Skip other endpoints if node is down

    # Network info
    try:
        resp = requests.get(f"{NODE_API_URL}/network/info", timeout=5)
        resp.raise_for_status()
        data = resp.json()

        node_peers.set(data.get("n_peers", 0))
        node_connections.set(data.get("n_connections", 0))
        node_pending_connections.set(data.get("n_pending_connections", 0))
    except Exception:
        pass

    # Wallet balances. Don't zero the gauge on failure — leaving the last
    # successful value avoids painting a fake "balance dropped to 0" line on
    # the chart when the wallet endpoint has a transient hiccup.
    keys = parse_wallet_keys(CONFIG_PATH)
    for key in keys:
        try:
            resp = requests.get(f"{NODE_API_URL}/wallet/{key}/balance", timeout=5)
            if resp.status_code == 200:
                wallet_balance.labels(key=key[:16]).set(resp.json().get("balance", 0))
            else:
                body = resp.text.strip().replace("\n", " ")[:200]
                log.warning("balance HTTP %s for key %s...: %s", resp.status_code, key[:16], body)
        except Exception as e:
            log.warning("balance error for key %s...: %s", key[:16], e)


def calculate_cpu_percent(stats):
    """Calculate CPU percentage from Docker stats, matching `docker stats` output."""
    cpu = stats.get("cpu_stats", {})
    precpu = stats.get("precpu_stats", {})

    cpu_delta = cpu.get("cpu_usage", {}).get("total_usage", 0) - \
                precpu.get("cpu_usage", {}).get("total_usage", 0)
    system_delta = cpu.get("system_cpu_usage", 0) - \
                   precpu.get("system_cpu_usage", 0)

    if system_delta > 0 and cpu_delta > 0:
        num_cpus = len(cpu.get("cpu_usage", {}).get("percpu_usage", [])) or \
                   cpu.get("online_cpus", 1)
        return (cpu_delta / system_delta) * num_cpus * 100.0
    return 0.0


def poll_docker_stats():
    """Poll Docker stats API for the node container."""
    try:
        client = docker.DockerClient.from_env()
        container = client.containers.get(CONTAINER_NAME)

        if container.status != "running":
            container_running.set(0)
            return

        container_running.set(1)

        stats = container.stats(stream=False)

        # CPU
        container_cpu.set(calculate_cpu_percent(stats))

        # Memory (cgroup v2 on newer kernels uses different keys)
        mem = stats.get("memory_stats", {})
        mem_usage = mem.get("usage", 0)
        mem_limit = mem.get("limit", 0)

        # cgroup v2 fallback: read from host cgroup filesystem (mounted at /host/sys/fs/cgroup)
        if not mem_usage or not mem_limit:
            try:
                container_full_id = container.id
                cgroup_host = "/host/sys/fs/cgroup"

                # Try common cgroup v2 paths for Docker containers
                cgroup_base = None
                for path in [
                    f"{cgroup_host}/system.slice/docker-{container_full_id}.scope",
                    f"{cgroup_host}/docker/{container_full_id}",
                ]:
                    if os.path.isdir(path):
                        cgroup_base = path
                        break

                if cgroup_base:
                    if not mem_usage:
                        p = os.path.join(cgroup_base, "memory.current")
                        if os.path.exists(p):
                            with open(p) as f:
                                mem_usage = int(f.read().strip())

                    if not mem_limit:
                        p = os.path.join(cgroup_base, "memory.max")
                        if os.path.exists(p):
                            val = open(p).read().strip()
                            if val != "max":
                                mem_limit = int(val)
                            else:
                                # "max" = no limit, use host total memory
                                mem_limit = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")

                    log.debug("cgroup v2 memory: usage=%s limit=%s (path=%s)", mem_usage, mem_limit, cgroup_base)
                else:
                    log.debug("cgroup v2: no cgroup dir found for container %s", container_full_id[:12])
            except Exception as e:
                log.debug("cgroup v2 memory fallback error: %s", e)

        container_memory.set(mem_usage)
        container_memory_limit.set(mem_limit)

        # Network I/O (sum all interfaces)
        networks = stats.get("networks", {})
        rx_total = sum(net.get("rx_bytes", 0) for net in networks.values())
        tx_total = sum(net.get("tx_bytes", 0) for net in networks.values())
        container_net_rx.set(rx_total)
        container_net_tx.set(tx_total)

    except docker.errors.NotFound:
        container_running.set(0)
    except Exception as e:
        log.warning("Docker stats error: %s", e)
        container_running.set(0)


def poll_host_metrics():
    """Poll host system metrics (memory, disk, load)."""
    try:
        # Memory from host's /proc/meminfo (mounted at /host/proc)
        meminfo_path = "/host/proc/meminfo" if os.path.exists("/host/proc/meminfo") else "/proc/meminfo"
        with open(meminfo_path, "r") as f:
            meminfo = {}
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    meminfo[parts[0].rstrip(":")] = int(parts[1]) * 1024  # kB to bytes

        total = meminfo.get("MemTotal", 0)
        available = meminfo.get("MemAvailable", 0)
        host_memory_total.set(total)
        host_memory_used.set(total - available)
    except Exception as e:
        log.debug("Host memory error: %s", e)

    try:
        # Load average
        load1, load5, load15 = os.getloadavg()
        host_load_1m.set(load1)
        host_load_5m.set(load5)
        host_load_15m.set(load15)
    except Exception as e:
        log.debug("Host load error: %s", e)

    try:
        # Disk usage for the data directory
        usage = shutil.disk_usage("/")
        host_disk_usage.set((usage.used / usage.total) * 100.0)
    except Exception as e:
        log.debug("Host disk error: %s", e)


def poll_loop():
    """Main polling loop running in a background thread."""
    log.info("Poll loop started")
    first_run = True
    while True:
        try:
            poll_node_api()
            poll_docker_stats()
            poll_host_metrics()
            if first_run:
                log.info("First poll completed successfully")
                first_run = False
        except Exception as e:
            log.error("Poll error: %s", e)
        time.sleep(POLL_INTERVAL)


def main():
    log.info(
        "Starting Logos Node exporter on :%d (polling %s every %ds)",
        EXPORTER_PORT, NODE_API_URL, POLL_INTERVAL,
    )

    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)

    # Run polling in background thread
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()

    # Keep main thread alive
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        log.info("Shutting down")


if __name__ == "__main__":
    main()
