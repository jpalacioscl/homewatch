#!/usr/bin/env bash
# homewatch setup — instala Docker si falta, detecta hardware y levanta el stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           homewatch — Frigate + Home Assistant setup            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Instalar Docker si no está disponible ──────────────────────────────────
_install_docker() {
    echo "Docker no encontrado. Instalando..."

    # Detectar método de elevación disponible
    ELEVATE=""
    if command -v pkexec &>/dev/null; then
        ELEVATE="pkexec"
    elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        ELEVATE="sudo"
    elif [[ "$EUID" -eq 0 ]]; then
        ELEVATE=""
    else
        echo "ERROR: Se necesita pkexec o sudo para instalar Docker."
        echo "Ejecuta manualmente: curl -fsSL https://get.docker.com | sudo sh"
        exit 1
    fi

    # Descargar script de instalación oficial
    TMP_INSTALLER=$(mktemp /tmp/get-docker-XXXXXX.sh)
    curl -fsSL https://get.docker.com -o "$TMP_INSTALLER"
    chmod +x "$TMP_INSTALLER"

    # Instalar
    $ELEVATE sh "$TMP_INSTALLER"
    rm -f "$TMP_INSTALLER"

    # Agregar usuario actual al grupo docker
    CURRENT_USER="${SUDO_USER:-${USER:-$(whoami)}}"
    $ELEVATE usermod -aG docker "$CURRENT_USER" 2>/dev/null || true

    # Activar grupo docker en la sesión actual sin relogin
    if command -v newgrp &>/dev/null; then
        newgrp docker || true
    fi

    echo "✓ Docker instalado"
    echo ""
}

if ! command -v docker &>/dev/null; then
    _install_docker
fi

# Verificar que el daemon esté corriendo
if ! docker info &>/dev/null 2>&1; then
    echo "El daemon de Docker no está corriendo. Intentando iniciarlo..."
    ELEVATE=""
    command -v pkexec &>/dev/null && ELEVATE="pkexec"
    command -v sudo &>/dev/null && sudo -n true 2>/dev/null && ELEVATE="sudo"
    $ELEVATE systemctl start docker 2>/dev/null || \
    $ELEVATE service docker start 2>/dev/null || true
    sleep 2
fi

# Si aún no tenemos acceso, usar pkexec como prefijo para docker
DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
    if command -v pkexec &>/dev/null; then
        DOCKER_CMD="pkexec docker"
        echo "ℹ  Usando pkexec para Docker (cierra sesión y vuelve a entrar para evitarlo)"
    else
        echo "ERROR: No se puede conectar al daemon de Docker."
        exit 1
    fi
fi

# ── 2. Detectar hardware y generar configuración ──────────────────────────────
bash "$SCRIPT_DIR/scripts/generate_config.sh"
echo ""

# ── 3. Configurar MQTT ────────────────────────────────────────────────────────
echo "Configurando MQTT..."
$DOCKER_CMD run --rm \
    -v "$SCRIPT_DIR/mosquitto/config:/mosquitto/config" \
    eclipse-mosquitto:2 \
    mosquitto_passwd -b /mosquitto/config/passwd frigate frigate_pass 2>/dev/null || true
echo "✓ MQTT configurado"

# ── 4. Verificar espacio en disco ─────────────────────────────────────────────
FREE_GB=$(df -BG "$SCRIPT_DIR" | awk 'NR==2{gsub("G","",$4); print $4}')
if [[ "$FREE_GB" -lt 20 ]]; then
    echo "⚠  Advertencia: menos de 20 GB libres (${FREE_GB}GB). Las grabaciones ocupan espacio rápidamente."
fi

# ── 5. Levantar el stack ──────────────────────────────────────────────────────
echo ""
echo "Levantando servicios..."
$DOCKER_CMD compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Stack levantado correctamente                                   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Frigate         → http://localhost:5000                        ║"
echo "║  Home Assistant  → http://localhost:8123                        ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Próximos pasos:                                                 ║"
echo "║  1. Abre frigate/config.yml y agrega tus cámaras (RTSP URLs)   ║"
echo "║  2. Reinicia Frigate:  docker restart frigate                   ║"
echo "║  3. Configura Home Assistant en http://localhost:8123           ║"
echo "║  4. Instala la app HA en tu celular para notificaciones push    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
