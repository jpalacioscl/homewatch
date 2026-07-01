#!/usr/bin/env bash
# homewatch setup — detecta hardware, genera configuración óptima y levanta el stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           homewatch — Frigate + Home Assistant setup            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# 1. Detectar hardware y generar configuración
bash "$SCRIPT_DIR/scripts/generate_config.sh"

echo ""

# 2. Crear contraseña MQTT para Frigate
echo "Configurando MQTT..."
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker no está instalado. Instálalo desde https://docs.docker.com/get-docker/"
    exit 1
fi

# Genera el archivo de passwords de mosquitto
docker run --rm \
    -v "$SCRIPT_DIR/mosquitto/config:/mosquitto/config" \
    eclipse-mosquitto:2 \
    mosquitto_passwd -b /mosquitto/config/passwd frigate frigate_pass 2>/dev/null || true

echo "✓ MQTT configurado"

# 3. Verificar espacio en disco
FREE_GB=$(df -BG "$SCRIPT_DIR" | awk 'NR==2{gsub("G","",$4); print $4}')
if [[ "$FREE_GB" -lt 20 ]]; then
    echo "⚠  Advertencia: menos de 20 GB libres (${FREE_GB}GB). Las grabaciones ocupan espacio rápidamente."
fi

# 4. Levantar el stack
echo ""
echo "Levantando servicios..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

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
