"""Server resource monitoring for U-Panel admin dashboard."""

from __future__ import annotations

import os
import platform
import socket
from datetime import datetime
from typing import Any

import psutil


def get_cpu_info() -> dict[str, Any]:
    """Get CPU usage and information."""
    cpu_percent = psutil.cpu_percent(interval=0.5)
    cpu_count_logical = psutil.cpu_count(logical=True)
    cpu_count_physical = psutil.cpu_count(logical=False)
    cpu_freq = psutil.cpu_freq()

    per_cpu = psutil.cpu_percent(interval=0.1, percpu=True)

    load_avg = None
    if hasattr(os, "getloadavg"):
        load_avg = os.getloadavg()

    return {
        "percent": cpu_percent,
        "count_logical": cpu_count_logical,
        "count_physical": cpu_count_physical,
        "frequency_current": round(cpu_freq.current, 1) if cpu_freq else None,
        "frequency_max": round(cpu_freq.max, 1) if cpu_freq and cpu_freq.max else None,
        "per_cpu_percent": per_cpu,
        "load_avg_1m": round(load_avg[0], 2) if load_avg else None,
        "load_avg_5m": round(load_avg[1], 2) if load_avg else None,
        "load_avg_15m": round(load_avg[2], 2) if load_avg else None,
    }


def get_memory_info() -> dict[str, Any]:
    """Get memory usage information."""
    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()

    return {
        "total": mem.total,
        "total_human": _bytes_to_human(mem.total),
        "available": mem.available,
        "available_human": _bytes_to_human(mem.available),
        "used": mem.used,
        "used_human": _bytes_to_human(mem.used),
        "percent": mem.percent,
        "swap_total": swap.total,
        "swap_total_human": _bytes_to_human(swap.total),
        "swap_used": swap.used,
        "swap_used_human": _bytes_to_human(swap.used),
        "swap_percent": swap.percent,
    }


def get_disk_info() -> list[dict[str, Any]]:
    """Get disk usage for all mounted partitions."""
    disks = []
    for partition in psutil.disk_partitions(all=False):
        try:
            usage = psutil.disk_usage(partition.mountpoint)
            disks.append(
                {
                    "device": partition.device,
                    "mountpoint": partition.mountpoint,
                    "fstype": partition.fstype,
                    "total": usage.total,
                    "total_human": _bytes_to_human(usage.total),
                    "used": usage.used,
                    "used_human": _bytes_to_human(usage.used),
                    "free": usage.free,
                    "free_human": _bytes_to_human(usage.free),
                    "percent": usage.percent,
                }
            )
        except (PermissionError, OSError):
            continue
    return disks


def get_network_info() -> dict[str, Any]:
    """Get network interface information and I/O counters."""
    net_io = psutil.net_io_counters()
    net_if_addrs = psutil.net_if_addrs()

    interfaces = []
    for name, addrs in net_if_addrs.items():
        iface = {"name": name, "addresses": []}
        for addr in addrs:
            if addr.family == socket.AF_INET:
                iface["addresses"].append(
                    {"type": "IPv4", "address": addr.address, "netmask": addr.netmask}
                )
            elif addr.family == socket.AF_INET6:
                iface["addresses"].append({"type": "IPv6", "address": addr.address})
        if iface["addresses"]:
            interfaces.append(iface)

    return {
        "bytes_sent": net_io.bytes_sent,
        "bytes_sent_human": _bytes_to_human(net_io.bytes_sent),
        "bytes_recv": net_io.bytes_recv,
        "bytes_recv_human": _bytes_to_human(net_io.bytes_recv),
        "packets_sent": net_io.packets_sent,
        "packets_recv": net_io.packets_recv,
        "errors_in": net_io.errin,
        "errors_out": net_io.errout,
        "interfaces": interfaces,
    }


def get_process_info() -> dict[str, Any]:
    """Get process information."""
    processes = []
    for proc in psutil.process_iter(["pid", "name", "cpu_percent", "memory_percent", "status"]):
        try:
            info = proc.info
            if info["cpu_percent"] is not None and info["memory_percent"] is not None:
                processes.append(info)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    processes.sort(key=lambda x: x["cpu_percent"] or 0, reverse=True)
    top_by_cpu = processes[:10]

    processes.sort(key=lambda x: x["memory_percent"] or 0, reverse=True)
    top_by_memory = processes[:10]

    status_counts = {}
    for proc in processes:
        status = proc.get("status", "unknown")
        status_counts[status] = status_counts.get(status, 0) + 1

    return {
        "total": len(processes),
        "top_by_cpu": top_by_cpu,
        "top_by_memory": top_by_memory,
        "status_counts": status_counts,
    }


def get_system_info() -> dict[str, Any]:
    """Get general system information."""
    boot_time = datetime.fromtimestamp(psutil.boot_time())
    uptime_seconds = (datetime.now() - boot_time).total_seconds()

    return {
        "hostname": socket.gethostname(),
        "platform": platform.system(),
        "platform_release": platform.release(),
        "platform_version": platform.version(),
        "architecture": platform.machine(),
        "processor": platform.processor() or "Unknown",
        "python_version": platform.python_version(),
        "boot_time": boot_time.isoformat(),
        "boot_time_human": boot_time.strftime("%Y-%m-%d %H:%M:%S"),
        "uptime_seconds": int(uptime_seconds),
        "uptime_human": _seconds_to_human(uptime_seconds),
    }


def get_disk_io_info() -> dict[str, Any] | None:
    """Get disk I/O counters."""
    try:
        io_counters = psutil.disk_io_counters()
        if io_counters:
            return {
                "read_bytes": io_counters.read_bytes,
                "read_bytes_human": _bytes_to_human(io_counters.read_bytes),
                "write_bytes": io_counters.write_bytes,
                "write_bytes_human": _bytes_to_human(io_counters.write_bytes),
                "read_count": io_counters.read_count,
                "write_count": io_counters.write_count,
            }
    except Exception:
        pass
    return None


def get_server_health() -> dict[str, Any]:
    """Get complete server health information."""
    return {
        "system": get_system_info(),
        "cpu": get_cpu_info(),
        "memory": get_memory_info(),
        "disks": get_disk_info(),
        "disk_io": get_disk_io_info(),
        "network": get_network_info(),
        "processes": get_process_info(),
        "timestamp": datetime.now().isoformat(),
    }


def get_health_status() -> dict[str, Any]:
    """Get a health status summary with severity levels."""
    health = get_server_health()

    issues = []
    status = "healthy"

    cpu_percent = health["cpu"]["percent"]
    if cpu_percent > 90:
        issues.append({"type": "cpu", "severity": "critical", "message": f"CPU usage critical: {cpu_percent}%"})
        status = "critical"
    elif cpu_percent > 75:
        issues.append({"type": "cpu", "severity": "warning", "message": f"CPU usage high: {cpu_percent}%"})
        if status != "critical":
            status = "warning"

    mem_percent = health["memory"]["percent"]
    if mem_percent > 90:
        issues.append({"type": "memory", "severity": "critical", "message": f"Memory usage critical: {mem_percent}%"})
        status = "critical"
    elif mem_percent > 80:
        issues.append({"type": "memory", "severity": "warning", "message": f"Memory usage high: {mem_percent}%"})
        if status != "critical":
            status = "warning"

    for disk in health["disks"]:
        if disk["percent"] > 90:
            issues.append(
                {
                    "type": "disk",
                    "severity": "critical",
                    "message": f"Disk {disk['mountpoint']} critical: {disk['percent']}% used",
                }
            )
            status = "critical"
        elif disk["percent"] > 80:
            issues.append(
                {
                    "type": "disk",
                    "severity": "warning",
                    "message": f"Disk {disk['mountpoint']} warning: {disk['percent']}% used",
                }
            )
            if status != "critical":
                status = "warning"

    return {
        "status": status,
        "issues": issues,
        "health": health,
    }


def _bytes_to_human(num_bytes: int) -> str:
    """Convert bytes to human-readable format."""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(num_bytes) < 1024:
            return f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f} PB"


def _seconds_to_human(seconds: float) -> str:
    """Convert seconds to human-readable uptime format."""
    days, remainder = divmod(int(seconds), 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, secs = divmod(remainder, 60)

    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if secs or not parts:
        parts.append(f"{secs}s")

    return " ".join(parts)
