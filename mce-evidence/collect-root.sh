#!/usr/bin/env bash
# Run as root:  sudo bash collect-root.sh
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "== dmidecode =="
dmidecode -t 16,17 > "$D/dmi-memory.txt" 2>&1 || echo "dmidecode unavailable/failed"
echo "== dmesg (MCE) =="
dmesg 2>/dev/null | grep -E 'Hardware Error|Machine check' > "$D/dmesg-mce.txt" 2>&1 || true
echo "== amd64_edac probe =="
modprobe amd64_edac 2>&1 | tee "$D/amd64_edac-load.txt"
echo "== EDAC nodes after probe =="
{ ls -la /sys/devices/system/edac/mc/; find /sys/devices/system/edac/mc -maxdepth 2 2>/dev/null; } > "$D/edac-nodes.txt" 2>&1
echo "== AGESA (SMBIOS Type 40) =="
dmidecode -t 40 > "$D/agesa.txt" 2>&1 || true
echo "done -> $D"
