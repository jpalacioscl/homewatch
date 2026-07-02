#!/usr/bin/env bash
# homewatch — instalación completa en un solo script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ─────────────────────────────────────────────────────────────────────────────
_titulo() { echo ""; echo "▶  $1"; echo ""; }
_ok()     { echo "   ✓  $1"; }
_info()   { echo "   ℹ  $1"; }
_error()  { echo ""; echo "   ✗  ERROR: $1"; echo ""; exit 1; }

_elevate() {
    if   command -v pkexec &>/dev/null;                        then echo "pkexec"
    elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then echo "sudo"
    elif [[ "$EUID" -eq 0 ]];                                  then echo ""
    else _error "Se necesita permiso de administrador. Instala sudo o pkexec."; fi
}
# ─────────────────────────────────────────────────────────────────────────────

clear
echo ""
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║        homewatch — Sistema de vigilancia con IA          ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "  Este asistente instalará y configurará todo automáticamente."
echo "  Solo necesitas responder un par de preguntas."
echo ""
echo "  Presiona ENTER para continuar..."
read -r

# ── PASO 1: Docker ────────────────────────────────────────────────────────────
_titulo "PASO 1/4 — Verificando Docker"

if ! command -v docker &>/dev/null; then
    _info "Docker no está instalado. Instalando ahora..."
    _info "Se te pedirá la contraseña de administrador."
    echo ""
    ELEV=$(_elevate)
    TMP=$(mktemp /tmp/get-docker-XXXXXX.sh)
    curl -fsSL https://get.docker.com -o "$TMP"
    $ELEV sh "$TMP"
    rm -f "$TMP"
    CURRENT_USER="${SUDO_USER:-${USER:-$(whoami)}}"
    $ELEV usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
    _ok "Docker instalado"
else
    _ok "Docker ya está instalado"
fi

# Asegurarse de que el daemon esté corriendo
if ! docker info &>/dev/null 2>&1; then
    ELEV=$(_elevate)
    $ELEV systemctl start docker 2>/dev/null || $ELEV service docker start 2>/dev/null || true
    sleep 2
fi

DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then
    command -v pkexec &>/dev/null && DOCKER="pkexec docker" || _error "No se puede conectar a Docker."
fi

# ── PASO 2: NVIDIA Container Toolkit si hay GPU NVIDIA ───────────────────────
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    if ! $DOCKER info 2>/dev/null | grep -q "nvidia"; then
        _info "GPU NVIDIA detectada — instalando soporte Docker para NVIDIA..."
        ELEV=$(_elevate)
        $ELEV sh -c "
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
              | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
              | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
              | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
            apt-get update -qq && apt-get install -y nvidia-container-toolkit -qq
            nvidia-ctk runtime configure --runtime=docker >/dev/null
            systemctl restart docker
        " 2>/dev/null
        _ok "NVIDIA Container Toolkit instalado"
    else
        _ok "Soporte NVIDIA para Docker ya activo"
    fi
fi

# ── PASO 3: Detectar tu computador ───────────────────────────────────────────
_titulo "PASO 3/5 — Detectando tu computador"
bash "$SCRIPT_DIR/scripts/generate_config.sh"

# ── PASO 3: Acceso remoto desde tu celular ────────────────────────────────────
_titulo "PASO 3/4 — Acceso remoto desde tu celular"
echo "  ¿Quieres ver las cámaras desde tu celular aunque no estés en casa?"
echo ""
echo "  [S] Sí, configurar acceso remoto gratis (recomendado)"
echo "  [N] No, solo usarlo en casa por ahora"
echo ""
read -rp "  Tu respuesta (S/N): " REMOTE_CHOICE
echo ""

TUNNEL_TOKEN=""
if [[ "${REMOTE_CHOICE,,}" == "s" ]]; then
    echo "  Vamos a conectarlo a Cloudflare (es gratis y muy seguro)."
    echo "  Sigue estos pasos — solo toma 2 minutos:"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  1. Abre esta página en tu navegador:                   │"
    echo "  │     https://cloudflare.com  →  crea una cuenta gratis  │"
    echo "  │                                                         │"
    echo "  │  2. Una vez dentro, ve a:                               │"
    echo "  │     https://one.dash.cloudflare.com                     │"
    echo "  │                                                         │"
    echo "  │  3. En el menú izquierdo:                               │"
    echo "  │     Networks → Tunnels → Create a tunnel                │"
    echo "  │                                                         │"
    echo "  │  4. Elige 'Cloudflared' → ponle nombre 'homewatch'     │"
    echo "  │     → Next → copia el TOKEN que aparece                 │"
    echo "  │                                                         │"
    echo "  │  5. En 'Public Hostname' agrega:                        │"
    echo "  │     Subdomain: casa                                     │"
    echo "  │     Service:   http://homeassistant:8123                │"
    echo "  │     (usa cualquier dominio que tengas en Cloudflare,    │"
    echo "  │      o crea uno gratis en freenom.com)                  │"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""
    read -rp "  Pega aquí el token de Cloudflare: " TUNNEL_TOKEN
    echo ""

    if [[ -n "$TUNNEL_TOKEN" ]]; then
        grep -v "^CLOUDFLARE_TUNNEL_TOKEN=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
        mv "${ENV_FILE}.tmp" "$ENV_FILE" 2>/dev/null || true
        echo "CLOUDFLARE_TUNNEL_TOKEN=$TUNNEL_TOKEN" >> "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        _ok "Acceso remoto configurado"
    else
        _info "Token vacío — se omite el acceso remoto. Puedes configurarlo después."
    fi
else
    _info "Sin acceso remoto por ahora. Puedes agregarlo después ejecutando este mismo script."
fi

# ── PASO 4: Buscar cámaras en la red ─────────────────────────────────────────
_titulo "PASO 4/5 — Buscando cámaras en tu red"

# Instalar dependencias de escaneo si faltan
PYTHON=$(command -v python3 || command -v python || true)
if [[ -z "$PYTHON" ]]; then
    warn "Python no encontrado — omitiendo detección de cámaras."
else
    for pkg in wsdiscovery onvif-zeep; do
        $PYTHON -c "import ${pkg//-/_}" 2>/dev/null || \
            $PYTHON -m pip install "$pkg" -q --break-system-packages 2>/dev/null || true
    done

    if ! command -v nmap &>/dev/null; then
        _info "Instalando nmap para escanear la red..."
        ELEV=$(_elevate)
        $ELEV apt-get install -y nmap -qq 2>/dev/null || \
        $ELEV yum install -y nmap -q 2>/dev/null || true
    fi

    echo ""
    echo "  ¿Quieres que busque cámaras automáticamente en tu red?"
    echo "  Necesitas tener las cámaras encendidas y conectadas al WiFi/router."
    echo ""
    read -rp "  [S] Sí, buscar cámaras ahora   [N] No, las agrego después  (S/N): " SCAN_CHOICE
    echo ""

    if [[ "${SCAN_CHOICE,,}" == "s" ]]; then
        $PYTHON "$SCRIPT_DIR/scripts/scan_cameras.py"
    else
        _info "Puedes buscar cámaras después ejecutando:"
        _info "  python3 scripts/scan_cameras.py"
    fi
fi

# ── PASO 5: Instalar y arrancar todo ─────────────────────────────────────────
_titulo "PASO 5/5 — Instalando y arrancando"

_info "Configurando servidor de mensajes (MQTT)..."
$DOCKER run --rm \
    -v "$SCRIPT_DIR/mosquitto/config:/mosquitto/config" \
    eclipse-mosquitto:2 \
    mosquitto_passwd -b /mosquitto/config/passwd frigate frigate_pass 2>/dev/null || true
_ok "MQTT listo"

FREE_GB=$(df -BG "$SCRIPT_DIR" | awk 'NR==2{gsub("G","",$4); print $4}')
if [[ "$FREE_GB" -lt 20 ]]; then
    _info "Advertencia: solo ${FREE_GB}GB libres en disco. Las grabaciones ocupan espacio. Libera espacio si puedes."
fi

_info "Descargando e iniciando servicios (puede tardar unos minutos la primera vez)..."
echo ""

if [[ -n "$TUNNEL_TOKEN" && -f "$ENV_FILE" ]]; then
    $DOCKER compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$ENV_FILE" --profile tunnel up -d
else
    $DOCKER compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
fi

# ── LISTO ─────────────────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo "  ╔═══════════════════════════════════════════════════════════╗"
echo "  ║                   ¡Todo listo!                           ║"
echo "  ╠═══════════════════════════════════════════════════════════╣"
echo "  ║                                                           ║"
echo "  ║  Abre en tu navegador (en esta red):                     ║"
printf "  ║  → Panel principal:   http://%-27s║\n" "${LOCAL_IP}:8123  "
printf "  ║  → Cámaras (Frigate): http://%-27s║\n" "${LOCAL_IP}:5000  "
if [[ -n "$TUNNEL_TOKEN" ]]; then
echo "  ║                                                           ║"
echo "  ║  Desde cualquier lugar (celular, etc.):                  ║"
echo "  ║  → La URL que configuraste en Cloudflare                 ║"
fi
echo "  ║                                                           ║"
echo "  ╠═══════════════════════════════════════════════════════════╣"
echo "  ║  Próximo paso:                                            ║"
echo "  ║  Agrega tus cámaras editando:                            ║"
echo "  ║  frigate/config.yml  (busca la sección 'cameras')        ║"
echo "  ╚═══════════════════════════════════════════════════════════╝"
echo ""
