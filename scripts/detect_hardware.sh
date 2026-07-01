#!/usr/bin/env bash
# Detects hardware and exports variables used by setup.sh to generate
# optimal Frigate + Home Assistant configuration.
set -euo pipefail

# ── CPU ───────────────────────────────────────────────────────────────────────
CPU_CORES=$(nproc)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
CPU_ARCH=$(uname -m)

# ── RAM ───────────────────────────────────────────────────────────────────────
RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
RAM_GB=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)

# ── GPU ───────────────────────────────────────────────────────────────────────
GPU_TYPE="cpu"
GPU_MODEL="none"

# NVIDIA
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    GPU_TYPE="nvidia"
    GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
# Intel (VA-API)
elif lspci 2>/dev/null | grep -qi "intel.*uhd\|intel.*iris\|intel.*graphics"; then
    GPU_TYPE="intel"
    GPU_MODEL=$(lspci 2>/dev/null | grep -i "intel.*graphics\|intel.*uhd\|intel.*iris" | head -1 | sed 's/.*: //' || echo "Intel GPU")
# AMD
elif lspci 2>/dev/null | grep -qi "amd.*radeon\|advanced micro.*radeon"; then
    GPU_TYPE="amd"
    GPU_MODEL=$(lspci 2>/dev/null | grep -i "radeon" | head -1 | sed 's/.*: //' || echo "AMD GPU")
fi

# Google Coral TPU (USB or PCIe) — overrides GPU choice for detection
CORAL_DETECTED="false"
if lsusb 2>/dev/null | grep -qi "1a6e:089a\|18d1:9302"; then
    CORAL_DETECTED="true"
elif lspci 2>/dev/null | grep -qi "global unichip\|1ac1:089a"; then
    CORAL_DETECTED="true"
fi

# ── STORAGE ───────────────────────────────────────────────────────────────────
# Find the disk backing the current directory
STORAGE_PATH="$(pwd)"
STORAGE_DEVICE=$(df "$STORAGE_PATH" 2>/dev/null | awk 'NR==2{print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||')
STORAGE_TYPE="hdd"
ROT_FILE="/sys/block/${STORAGE_DEVICE}/queue/rotational"
if [[ -f "$ROT_FILE" ]]; then
    [[ "$(cat "$ROT_FILE")" == "0" ]] && STORAGE_TYPE="ssd"
elif [[ "$STORAGE_DEVICE" == nvme* ]]; then
    STORAGE_TYPE="nvme"
fi

STORAGE_FREE_GB=$(df -BG "$STORAGE_PATH" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || echo "0")

# ── FRIGATE DETECTOR SELECTION ────────────────────────────────────────────────
if [[ "$CORAL_DETECTED" == "true" ]]; then
    FRIGATE_DETECTOR="coral"
    FRIGATE_DETECTOR_LABEL="Google Coral TPU"
elif [[ "$GPU_TYPE" == "nvidia" ]]; then
    FRIGATE_DETECTOR="tensorrt"
    FRIGATE_DETECTOR_LABEL="NVIDIA TensorRT ($GPU_MODEL)"
elif [[ "$GPU_TYPE" == "intel" ]]; then
    FRIGATE_DETECTOR="openvino"
    FRIGATE_DETECTOR_LABEL="Intel OpenVINO ($GPU_MODEL)"
else
    FRIGATE_DETECTOR="cpu"
    FRIGATE_DETECTOR_LABEL="CPU ($CPU_MODEL)"
fi

# ── PERFORMANCE TUNING ────────────────────────────────────────────────────────
# Detection processes: half the cores, min 1, max 4
DETECT_PROCESSES=$(( CPU_CORES / 2 ))
[[ "$DETECT_PROCESSES" -lt 1 ]] && DETECT_PROCESSES=1
[[ "$DETECT_PROCESSES" -gt 4 ]] && DETECT_PROCESSES=4

# Recording quality based on RAM and storage
# HDD with >1 TB free is fine for high quality multi-camera recording
STORAGE_OK_FOR_HIGH="false"
[[ "$STORAGE_TYPE" != "hdd" ]] && STORAGE_OK_FOR_HIGH="true"
[[ "$STORAGE_TYPE" == "hdd" && "$STORAGE_FREE_GB" -ge 1000 ]] && STORAGE_OK_FOR_HIGH="true"

if [[ "$RAM_MB" -ge 8192 && "$STORAGE_OK_FOR_HIGH" == "true" ]]; then
    RECORDING_QUALITY="high"    # high quality, retain 30 days
    RETAIN_DAYS=30
    SNAPSHOTS_RETAIN_DAYS=30
elif [[ "$RAM_MB" -ge 4096 ]]; then
    RECORDING_QUALITY="medium"  # medium quality, retain 14 days
    RETAIN_DAYS=14
    SNAPSHOTS_RETAIN_DAYS=14
else
    RECORDING_QUALITY="low"     # low quality, retain 7 days (low RAM or full disk)
    RETAIN_DAYS=7
    SNAPSHOTS_RETAIN_DAYS=7
fi

# FFMPEG hardware decode preset
case "$GPU_TYPE" in
    nvidia) FFMPEG_PRESET="preset-nvidia-h264" ;;
    intel)  FFMPEG_PRESET="preset-vaapi" ;;
    *)      FFMPEG_PRESET="preset-rpi4" ;;   # safe CPU fallback
esac

# Docker memory limit for Frigate
if [[ "$RAM_MB" -ge 8192 ]]; then
    FRIGATE_MEM_LIMIT="4g"
elif [[ "$RAM_MB" -ge 4096 ]]; then
    FRIGATE_MEM_LIMIT="2g"
else
    FRIGATE_MEM_LIMIT="1g"
fi

# ── EXPORT ────────────────────────────────────────────────────────────────────
export CPU_CORES CPU_MODEL CPU_ARCH
export RAM_MB RAM_GB
export GPU_TYPE GPU_MODEL
export CORAL_DETECTED
export STORAGE_TYPE STORAGE_FREE_GB
export FRIGATE_DETECTOR FRIGATE_DETECTOR_LABEL
export DETECT_PROCESSES
export RECORDING_QUALITY RETAIN_DAYS SNAPSHOTS_RETAIN_DAYS
export FFMPEG_PRESET FRIGATE_MEM_LIMIT

# ── REPORT ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Hardware detectado"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  CPU        : %s (%d cores, %s)\n" "$CPU_MODEL" "$CPU_CORES" "$CPU_ARCH"
printf "  RAM        : %s GB\n" "$RAM_GB"
printf "  GPU        : %s\n" "${GPU_MODEL:-none}"
printf "  Coral TPU  : %s\n" "$CORAL_DETECTED"
printf "  Storage    : %s  (%s GB libres)\n" "${STORAGE_TYPE^^}" "$STORAGE_FREE_GB"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configuración óptima seleccionada"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Detector IA  : %s\n" "$FRIGATE_DETECTOR_LABEL"
printf "  Procesos     : %d detección paralela\n" "$DETECT_PROCESSES"
printf "  Calidad      : %s\n" "$RECORDING_QUALITY"
printf "  Retención    : %d días grabaciones / %d días snapshots\n" "$RETAIN_DAYS" "$SNAPSHOTS_RETAIN_DAYS"
printf "  FFMPEG       : %s\n" "$FFMPEG_PRESET"
printf "  RAM Frigate  : %s límite\n" "$FRIGATE_MEM_LIMIT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
