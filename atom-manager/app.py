"""
ATOM System Manager API
Provides real-time system stats and service group management.
Runs as a systemd service on port 9000, proxied via nginx at /atom-api/.
"""

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
import asyncio
import subprocess
import json
import time
import os

app = FastAPI(title="ATOM System Manager")

SERVICE_GROUPS = {
    "comfyui": {
        "name": "ComfyUI",
        "description": "AI image generation with Stable Diffusion",
        "services": [
            {"name": "comfyui", "type": "systemd", "label": "ComfyUI"},
        ],
        "docker": [],
        "url": "/comfyui/",
    },
    "codeserver": {
        "name": "Code Server",
        "description": "VS Code in browser with AI coding",
        "services": [
            {"name": "code-server@{{USER}}", "type": "systemd", "label": "code-server"},
        ],
        "docker": [],
        "url": "/code/",
    },
    "ollama": {
        "name": "Ollama",
        "description": "LLM inference API",
        "services": [
            {"name": "ollama", "type": "systemd", "label": "Ollama"},
        ],
        "docker": [],
        "url": "/ollama/",
    },
    "infrastructure": {
        "name": "Infrastructure",
        "description": "Core infrastructure services",
        "services": [
            {"name": "nginx", "type": "systemd", "label": "Nginx"},
            {"name": "cloudflared", "type": "systemd", "label": "Cloudflare Tunnel"},
            {"name": "atom-manager", "type": "systemd", "label": "System Manager API"},
        ],
        "docker": [],
        "url": None,
    },
}


def run_cmd(cmd, timeout=10):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip()
    except Exception as e:
        return str(e)


def get_service_status(name):
    return run_cmd(f"systemctl is-active {name}") == "active"


def get_docker_status(name):
    return bool(run_cmd(f"docker ps --filter name=^{name}$ --format '{{{{.Names}}}}'"))


def make_event(step, service, status):
    return "data: " + json.dumps({"step": step, "service": service, "status": status}) + "\n\n"


@app.get("/api/stats")
async def system_stats():
    stats = {}

    # CPU
    cpu_line = run_cmd("grep 'cpu ' /proc/stat")
    if cpu_line:
        parts = cpu_line.split()
        idle = int(parts[4])
        total = sum(int(x) for x in parts[1:])
        prev_file = "/tmp/atom_cpu_prev"
        try:
            with open(prev_file, 'r') as f:
                prev = json.load(f)
            diff_idle = idle - prev['idle']
            diff_total = total - prev['total']
            cpu_pct = round((1 - diff_idle / max(diff_total, 1)) * 100, 1)
        except Exception:
            cpu_pct = 0
        with open(prev_file, 'w') as f:
            json.dump({"idle": idle, "total": total}, f)
        stats["cpu_percent"] = cpu_pct
        stats["cpu_cores"] = int(run_cmd("nproc"))

    # Memory
    mem = run_cmd("free -b | grep Mem")
    if mem:
        parts = mem.split()
        total_b = int(parts[1])
        used_b = int(parts[2])
        stats["ram_total_gb"] = round(total_b / 1073741824, 1)
        stats["ram_used_gb"] = round(used_b / 1073741824, 1)
        stats["ram_percent"] = round(used_b / total_b * 100, 1)

    swap = run_cmd("free -b | grep Swap")
    if swap:
        parts = swap.split()
        stats["swap_total_gb"] = round(int(parts[1]) / 1073741824, 1)
        stats["swap_used_gb"] = round(int(parts[2]) / 1073741824, 1)

    # GPU
    gpu = run_cmd("nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null")
    if gpu:
        parts = [x.strip() for x in gpu.split(",")]
        stats["gpu_temp"] = int(parts[0]) if parts[0] not in ("[N/A]", "[Not Supported]") else None
        stats["gpu_util"] = int(parts[1]) if len(parts) > 1 and parts[1] not in ("[N/A]", "[Not Supported]") else None
        stats["gpu_power"] = float(parts[2]) if len(parts) > 2 and parts[2] not in ("[N/A]", "[Not Supported]") else None

    gpu_procs = run_cmd("nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null")
    gpu_mem_total = 0
    gpu_processes = []
    if gpu_procs:
        for line in gpu_procs.strip().split("\n"):
            if line.strip():
                parts = [x.strip() for x in line.split(",")]
                if len(parts) >= 3:
                    try:
                        mem_val = int(parts[2])
                    except ValueError:
                        continue
                    gpu_mem_total += mem_val
                    name = parts[1].split("/")[-1]
                    gpu_processes.append({"name": name, "mem_mb": mem_val})
    stats["gpu_mem_used_mb"] = gpu_mem_total
    stats["gpu_processes"] = gpu_processes

    # Disk
    disk = run_cmd("df -B1 / | tail -1")
    if disk:
        parts = disk.split()
        stats["disk_total_gb"] = round(int(parts[1]) / 1073741824)
        stats["disk_used_gb"] = round(int(parts[2]) / 1073741824)
        stats["disk_percent"] = int(parts[4].replace("%", ""))

    # Uptime in seconds
    uptime_str = run_cmd("cat /proc/uptime")
    if uptime_str:
        stats["uptime"] = int(float(uptime_str.split()[0]))

    # Network
    stats["tailscale_ip"] = run_cmd("tailscale ip -4 2>/dev/null") or None
    hostname = run_cmd("hostname")
    stats["public_url"] = f"{hostname}.{{{{DOMAIN}}}}"
    stats["ipv6"] = run_cmd("ip -6 addr show | grep 'inet6.*global' | head -1 | awk '{print $2}' | cut -d/ -f1")

    return stats


@app.get("/api/services")
async def list_services():
    groups = {}
    for gid, group in SERVICE_GROUPS.items():
        services = []
        all_active = True

        for svc in group["services"]:
            active = get_service_status(svc["name"])
            services.append({"name": svc["name"], "label": svc["label"], "active": active, "type": "systemd"})
            if not active:
                all_active = False

        for ctr in group.get("docker", []):
            active = get_docker_status(ctr["name"])
            services.append({"name": ctr["name"], "label": ctr["label"], "active": active, "type": "docker"})
            if not active:
                all_active = False

        if not services:
            all_active = False

        groups[gid] = {
            "name": group["name"],
            "description": group["description"],
            "url": group["url"],
            "active": all_active,
            "services": services,
        }
    return groups


@app.post("/api/services/{group_id}/start")
async def start_group(group_id: str):
    if group_id not in SERVICE_GROUPS:
        raise HTTPException(status_code=404, detail=f"Unknown group: {group_id}")
    group = SERVICE_GROUPS[group_id]

    async def stream():
        for svc in group["services"]:
            label = svc["label"]
            yield make_event(f"Starting {label}...", svc["name"], "starting")
            run_cmd(f"sudo systemctl start {svc['name']}", timeout=30)
            await asyncio.sleep(1)
            active = get_service_status(svc["name"])
            yield make_event(label, svc["name"], "active" if active else "failed")

        for ctr in group.get("docker", []):
            label = ctr["label"]
            yield make_event(f"Starting {label}...", ctr["name"], "starting")
            exists = run_cmd(f"docker ps -a --filter name=^{ctr['name']}$ --format '{{{{.Names}}}}'")
            if exists:
                run_cmd(f"docker start {ctr['name']}", timeout=60)
            elif "run_args" in ctr:
                run_cmd(f"docker run {ctr['run_args']} {ctr.get('image', '')}", timeout=120)
            await asyncio.sleep(2)
            active = get_docker_status(ctr["name"])
            yield make_event(label, ctr["name"], "active" if active else "failed")

        yield make_event("Done", "", "complete")

    return StreamingResponse(stream(), media_type="text/event-stream")


@app.post("/api/services/{group_id}/stop")
async def stop_group(group_id: str):
    if group_id not in SERVICE_GROUPS:
        raise HTTPException(status_code=404, detail=f"Unknown group: {group_id}")
    group = SERVICE_GROUPS[group_id]

    async def stream():
        for ctr in reversed(group.get("docker", [])):
            label = ctr["label"]
            yield make_event(f"Stopping {label}...", ctr["name"], "stopping")
            run_cmd(f"docker stop {ctr['name']}", timeout=30)
            await asyncio.sleep(1)
            yield make_event(label, ctr["name"], "stopped")

        for svc in reversed(group["services"]):
            label = svc["label"]
            yield make_event(f"Stopping {label}...", svc["name"], "stopping")
            run_cmd(f"sudo systemctl stop {svc['name']}", timeout=30)
            await asyncio.sleep(1)
            yield make_event(label, svc["name"], "stopped")

        yield make_event("Done", "", "complete")

    return StreamingResponse(stream(), media_type="text/event-stream")
