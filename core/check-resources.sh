#!/bin/bash
# check-resources.sh — Check if the system has enough memory, CPU, and disk to spawn a new agent.
# Part of the claude-bot framework.
#
# Exit codes:
#   0 — Resources available, safe to proceed
#   1 — Resources insufficient, should queue the request
#
# Usage:
#   if /opt/claude-bot/scripts/check-resources.sh; then
#     # spawn agent
#   else
#     # queue request
#   fi
#
# Thresholds (for t3.medium: 2 vCPU, 4GB RAM, 30GB EBS):
#   - Memory: reject if > 85% used
#   - CPU load: reject if 1-min load average > 3.0 (on 2-vCPU machine)
#   - Disk: reject if > 90% used (alert at 80%)
#
# Can also be sourced for the check_resources() function.

set -euo pipefail

# Configurable thresholds (can be overridden via environment)
MEMORY_THRESHOLD_PCT="${RESOURCE_MEMORY_THRESHOLD:-85}"
LOAD_THRESHOLD="${RESOURCE_LOAD_THRESHOLD:-3.0}"
DISK_THRESHOLD_PCT="${RESOURCE_DISK_THRESHOLD:-90}"
DISK_WARN_PCT="${RESOURCE_DISK_WARN_THRESHOLD:-80}"

check_resources() {
  # --- Memory check ---
  # Use /proc/meminfo for portability (works without `free` being installed)
  local mem_total mem_available mem_used_pct
  mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)

  if [ "$mem_total" -gt 0 ]; then
    mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
  else
    # Can't determine memory — assume OK
    mem_used_pct=0
  fi

  if [ "$mem_used_pct" -gt "$MEMORY_THRESHOLD_PCT" ]; then
    echo "RESOURCE_CHECK_FAIL: memory ${mem_used_pct}% used (threshold: ${MEMORY_THRESHOLD_PCT}%)"
    return 1
  fi

  # --- CPU load check ---
  local load_1min
  load_1min=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.0")

  # Compare floats using awk
  if awk "BEGIN {exit !($load_1min > $LOAD_THRESHOLD)}" 2>/dev/null; then
    echo "RESOURCE_CHECK_FAIL: load average ${load_1min} (threshold: ${LOAD_THRESHOLD})"
    return 1
  fi

  # --- Disk check ---
  local disk_used_pct
  disk_used_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo 0)

  if [ "$disk_used_pct" -gt "$DISK_THRESHOLD_PCT" ]; then
    echo "RESOURCE_CHECK_FAIL: disk ${disk_used_pct}% used (threshold: ${DISK_THRESHOLD_PCT}%)"
    return 1
  fi

  if [ "$disk_used_pct" -gt "$DISK_WARN_PCT" ]; then
    echo "RESOURCE_CHECK_WARN: disk ${disk_used_pct}% used (warn threshold: ${DISK_WARN_PCT}%)"
  fi

  echo "RESOURCE_CHECK_OK: memory ${mem_used_pct}%, load ${load_1min}, disk ${disk_used_pct}%"
  return 0
}

# Run check when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_resources
fi
