#!/usr/bin/env bash
# Configura Cloudflare Tunnel para acceso remoto seguro a Home Assistant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║         homewatch — Configurar acceso remoto (Cloudflare)      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Para obtener tu token de Cloudflare Tunnel:"
echo ""
echo "  1. Crea una cuenta gratis en https://cloudflare.com"
echo "  2. Ve a https://one.dash.cloudflare.com"
echo "  3. Menú izquierdo: Networks → Tunnels"
echo "  4. Clic en 'Create a tunnel' → elige 'Cloudflared'"
echo "  5. Dale un nombre (ej: homewatch)"
echo "  6. Copia el token que aparece en el paso 'Install connector'"
echo "  7. En 'Public Hostname' agrega:"
echo "       Subdomain: ha    Domain: tudominio.com    Service: http://homeassistant:8123"
echo "     (si no tienes dominio, usa un subdominio de workers.dev gratuito)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -rp "  Pega tu token aquí: " TUNNEL_TOKEN

if [[ -z "$TUNNEL_TOKEN" ]]; then
    echo "ERROR: token vacío. Abortando."
    exit 1
fi

# Guardar token en .env
if [[ -f "$ENV_FILE" ]]; then
    # Actualizar si ya existe
    grep -v "^CLOUDFLARE_TUNNEL_TOKEN=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
fi
echo "CLOUDFLARE_TUNNEL_TOKEN=$TUNNEL_TOKEN" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "✓ Token guardado en .env"

# Detectar comando docker
DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
    command -v pkexec &>/dev/null && DOCKER_CMD="pkexec docker"
fi

# Levantar cloudflared
echo ""
echo "Levantando Cloudflare Tunnel..."
$DOCKER_CMD compose \
    -f "$PROJECT_DIR/docker-compose.yml" \
    --env-file "$ENV_FILE" \
    --profile tunnel \
    up -d cloudflared

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Tunnel activo                                                   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Home Assistant accesible desde cualquier lugar en:             ║"
echo "║  → https://ha.tudominio.com  (el que configuraste en Cloudflare)║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Logs del tunnel:                                                ║"
echo "║    docker logs -f cloudflared                                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
