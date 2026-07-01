#!/usr/bin/env python3
"""
Escanea la red local, descubre cámaras IP (ONVIF + RTSP) y genera
la sección 'cameras:' para frigate/config.yml automáticamente.
"""
import argparse
import ipaddress
import json
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

# ── Colores ANSI ──────────────────────────────────────────────────────────────
G = "\033[32m"; Y = "\033[33m"; R = "\033[31m"; B = "\033[34m"; W = "\033[0m"; BOLD = "\033[1m"

def ok(msg):    print(f"   {G}✓{W}  {msg}")
def info(msg):  print(f"   {B}ℹ{W}  {msg}")
def warn(msg):  print(f"   {Y}⚠{W}  {msg}")
def found(msg): print(f"   {G}{BOLD}◉{W}  {msg}")
def step(msg):  print(f"\n{BOLD}▶  {msg}{W}\n")

# ── Patrones RTSP comunes por fabricante ─────────────────────────────────────
RTSP_PATTERNS = [
    # Genéricas
    "/stream1", "/stream2", "/live", "/live/ch0",
    "/h264", "/video1", "/video.h264",
    # Hikvision
    "/Streaming/Channels/101", "/Streaming/Channels/201",
    # Dahua
    "/cam/realmonitor?channel=1&subtype=0",
    "/cam/realmonitor?channel=1&subtype=1",
    # Reolink
    "/h264Preview_01_main", "/h264Preview_01_sub",
    # TP-Link Tapo
    "/stream1", "/stream2",
    # Axis
    "/axis-media/media.amp",
    # Amcrest / Foscam
    "/videoMain", "/videoSub",
    # Genéricas adicionales
    "/live/ch00_0", "/ch1/0", "/0/video1",
    "/11", "/12",
]

# ── Detectar rango de red local ───────────────────────────────────────────────
def get_local_network() -> list[str]:
    """Retorna lista de redes locales (ej: ['192.168.1.0/24'])."""
    nets = []
    try:
        result = subprocess.run(
            ["ip", "-4", "-o", "addr", "show"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                iface = parts[1]
                cidr  = parts[3]
                if iface in ("lo",) or iface.startswith("docker") or iface.startswith("br-"):
                    continue
                try:
                    net = ipaddress.ip_network(cidr, strict=False)
                    if net.is_private and net.prefixlen <= 24:
                        nets.append(str(net))
                except ValueError:
                    pass
    except Exception:
        pass
    return nets or ["192.168.1.0/24"]

# ── Escaneo de puertos con nmap ───────────────────────────────────────────────
def nmap_scan(network: str) -> list[str]:
    """Devuelve IPs con puerto 554 (RTSP) o 80/8080 abiertos."""
    info(f"Escaneando red {network} (puertos 554, 80, 8080)...")
    ips = []
    try:
        result = subprocess.run(
            ["nmap", "-p", "554,80,8080", "--open", "-oG", "-", network],
            capture_output=True, text=True, timeout=60
        )
        for line in result.stdout.splitlines():
            if "Ports:" in line and "open" in line:
                m = re.search(r"Host:\s+(\d+\.\d+\.\d+\.\d+)", line)
                if m:
                    ips.append(m.group(1))
    except FileNotFoundError:
        warn("nmap no está instalado — usando ping sweep básico.")
        ips = ping_sweep(network)
    except subprocess.TimeoutExpired:
        warn("nmap tardó demasiado — usando resultados parciales.")
    return ips

def ping_sweep(network: str) -> list[str]:
    """Fallback: ping a todos los hosts de la red."""
    net = ipaddress.ip_network(network, strict=False)
    alive = []
    lock = threading.Lock()

    def ping(ip):
        r = subprocess.run(
            ["ping", "-c", "1", "-W", "1", str(ip)],
            capture_output=True
        )
        if r.returncode == 0:
            with lock:
                alive.append(str(ip))

    threads = [threading.Thread(target=ping, args=(ip,)) for ip in list(net.hosts())[:254]]
    for t in threads: t.start()
    for t in threads: t.join()
    return alive

# ── WS-Discovery ONVIF ────────────────────────────────────────────────────────
def onvif_wsdiscovery() -> list[dict]:
    """Broadcast WS-Discovery para encontrar cámaras ONVIF."""
    cameras = []
    try:
        from wsdiscovery import WSDiscovery
        wsd = WSDiscovery()
        wsd.start()
        services = wsd.searchServices(timeout=5)
        for svc in services:
            for xaddr in svc.getXAddrs():
                m = re.search(r"(\d+\.\d+\.\d+\.\d+)", xaddr)
                if m:
                    cameras.append({
                        "ip": m.group(1),
                        "onvif_url": xaddr,
                        "source": "ONVIF/WS-Discovery",
                    })
        wsd.stop()
    except ImportError:
        warn("wsdiscovery no instalado — omitiendo búsqueda ONVIF.")
        warn("Instala con: pip3 install wsdiscovery")
    except Exception as e:
        warn(f"WS-Discovery falló: {e}")
    return cameras

# ── Obtener URL RTSP via ONVIF ────────────────────────────────────────────────
def get_rtsp_via_onvif(ip: str, user: str, password: str) -> Optional[str]:
    """Conecta a la cámara por ONVIF y obtiene la URL RTSP real."""
    try:
        from onvif import ONVIFCamera
        cam = ONVIFCamera(ip, 80, user, password, no_cache=True)
        media = cam.create_media_service()
        profiles = media.GetProfiles()
        if not profiles:
            return None
        token = profiles[0].token
        req = media.create_type("GetStreamUri")
        req.StreamSetup = {
            "Stream": "RTP-Unicast",
            "Transport": {"Protocol": "RTSP"},
        }
        req.ProfileToken = token
        uri = media.GetStreamUri(req).Uri
        # Inyectar credenciales en la URL
        uri = re.sub(r"rtsp://", f"rtsp://{user}:{password}@", uri)
        return uri
    except Exception:
        return None

# ── Verificar stream RTSP con ffprobe ─────────────────────────────────────────
def verify_rtsp(url: str, timeout: int = 8) -> bool:
    """Retorna True si ffprobe puede leer el stream."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json",
             "-show_streams", "-rtsp_transport", "tcp",
             f"-timeout", str(timeout * 1_000_000), url],
            capture_output=True, timeout=timeout + 2
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False

def check_rtsp_port(ip: str, port: int = 554, timeout: int = 2) -> bool:
    """Verifica si el puerto RTSP está abierto."""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except (OSError, socket.timeout):
        return False

# ── Probar patrones RTSP para un host ────────────────────────────────────────
def probe_rtsp_patterns(ip: str, user: str, password: str) -> Optional[str]:
    """Prueba patrones RTSP comunes y retorna la primera URL que funciona."""
    creds = f"{user}:{password}@" if user else ""
    for path in RTSP_PATTERNS:
        url = f"rtsp://{creds}{ip}:554{path}"
        if verify_rtsp(url, timeout=5):
            return url
    return None

# ── Generar bloque YAML para una cámara ──────────────────────────────────────
def camera_yaml(name: str, rtsp_url: str, width: int = 1280, height: int = 720) -> str:
    safe_name = re.sub(r"[^a-z0-9_]", "_", name.lower())
    return f"""  {safe_name}:
    ffmpeg:
      inputs:
        - path: {rtsp_url}
          roles:
            - detect
            - record
    detect:
      width: {width}
      height: {height}
      fps: 5
    # zones:          # descomenta para definir zonas de detección
    #   zona_entrada:
    #     coordinates: 0,720,1280,720,1280,0,0,0
"""

# ── Script principal ──────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Escanea la red y detecta cámaras IP")
    parser.add_argument("--user",     default="admin",  help="Usuario de las cámaras (default: admin)")
    parser.add_argument("--password", default="",       help="Contraseña de las cámaras")
    parser.add_argument("--network",  default="",       help="Red a escanear (ej: 192.168.1.0/24)")
    parser.add_argument("--output",   default="",       help="Archivo de salida (default: frigate/config.yml)")
    parser.add_argument("--dry-run",  action="store_true", help="Solo mostrar, no escribir config")
    args = parser.parse_args()

    print("")
    print(f"  {BOLD}╔══════════════════════════════════════════════════════════╗{W}")
    print(f"  {BOLD}║       homewatch — Detector de cámaras en la red         ║{W}")
    print(f"  {BOLD}╚══════════════════════════════════════════════════════════╝{W}")
    print("")

    # Credenciales interactivas si no se pasaron por argumento
    user     = args.user
    password = args.password
    if not password:
        print("  La mayoría de cámaras usan usuario/contraseña para conectarse.")
        print("  Si todas usan las mismas credenciales, ingrésalas aquí.")
        print("  (Si son diferentes, las puedes editar luego en frigate/config.yml)")
        print("")
        user     = input(f"  Usuario de las cámaras [{args.user}]: ").strip() or args.user
        password = input(f"  Contraseña de las cámaras: ").strip()
        print("")

    # Red a escanear
    if args.network:
        networks = [args.network]
    else:
        networks = get_local_network()
        info(f"Red detectada: {', '.join(networks)}")

    # ── Fase 1: WS-Discovery ONVIF ────────────────────────────────────────────
    step("Buscando cámaras ONVIF en la red...")
    onvif_cameras = onvif_wsdiscovery()
    onvif_ips = {c["ip"] for c in onvif_cameras}
    if onvif_cameras:
        ok(f"WS-Discovery encontró {len(onvif_cameras)} cámara(s) ONVIF")
    else:
        info("No se encontraron cámaras ONVIF por broadcast")

    # ── Fase 2: Escaneo de puertos ────────────────────────────────────────────
    step("Escaneando puertos RTSP en la red...")
    scanned_ips = []
    for net in networks:
        scanned_ips += nmap_scan(net)

    # Combinar sin duplicados
    all_ips = list({*onvif_ips, *scanned_ips})
    if not all_ips:
        warn("No se encontraron dispositivos en la red.")
        sys.exit(0)
    info(f"Dispositivos a verificar: {len(all_ips)}")

    # ── Fase 3: Verificar streams ─────────────────────────────────────────────
    step("Verificando streams de video...")
    discovered = []

    for ip in sorted(all_ips):
        print(f"   Probando {ip}...", end=" ", flush=True)

        rtsp_url = None
        source   = "RTSP"

        # Primero intentar ONVIF si la cámara lo soporta
        if ip in onvif_ips and (user or password):
            rtsp_url = get_rtsp_via_onvif(ip, user, password)
            if rtsp_url:
                source = "ONVIF"

        # Si ONVIF no funcionó, probar patrones RTSP
        if not rtsp_url and check_rtsp_port(ip):
            rtsp_url = probe_rtsp_patterns(ip, user, password)

        if rtsp_url:
            print(f"{G}✓ stream OK{W}")
            idx = len(discovered) + 1
            discovered.append({
                "name":     f"camara_{idx}",
                "ip":       ip,
                "rtsp_url": rtsp_url,
                "source":   source,
            })
            found(f"Cámara {idx} — {ip}  [{source}]")
            info(f"  URL: {rtsp_url}")
        else:
            print(f"{Y}sin stream{W}")

    # ── Fase 4: Resultado ─────────────────────────────────────────────────────
    print("")
    if not discovered:
        warn("No se encontraron cámaras con stream funcional.")
        warn("Verifica que las cámaras estén encendidas y en la misma red.")
        sys.exit(0)

    print(f"  {G}{BOLD}Se encontraron {len(discovered)} cámara(s){W}")
    print("")

    # Permitir renombrar cámaras
    print("  Puedes darle un nombre descriptivo a cada cámara (ej: entrada, cocina, patio)")
    print("  o presiona ENTER para usar el nombre por defecto.")
    print("")
    for cam in discovered:
        nuevo = input(f"  Nombre para cámara en {cam['ip']} [{cam['name']}]: ").strip()
        if nuevo:
            cam["name"] = re.sub(r"\s+", "_", nuevo)

    # ── Fase 5: Generar config de Frigate ─────────────────────────────────────
    cameras_yaml = "\ncameras:\n"
    for cam in discovered:
        cameras_yaml += camera_yaml(cam["name"], cam["rtsp_url"])

    # Guardar resultado JSON para referencia
    json_path = Path(__file__).parent.parent / "frigate" / "discovered_cameras.json"
    json_path.write_text(json.dumps(discovered, indent=2, ensure_ascii=False))
    ok(f"Resumen guardado en frigate/discovered_cameras.json")

    if args.dry_run:
        print("\n  --- Vista previa (--dry-run) ---")
        print(cameras_yaml)
        sys.exit(0)

    # Inyectar en frigate/config.yml
    config_path = Path(args.output) if args.output else Path(__file__).parent.parent / "frigate" / "config.yml"
    if config_path.exists():
        content = config_path.read_text(encoding="utf-8")
        # Reemplazar sección cameras si ya existe
        content = re.sub(r"\ncameras:.*", "", content, flags=re.DOTALL)
        content = content.rstrip() + "\n" + cameras_yaml
        config_path.write_text(content, encoding="utf-8")
        ok(f"Cámaras agregadas a {config_path}")
    else:
        config_path.write_text(cameras_yaml, encoding="utf-8")
        ok(f"Configuración guardada en {config_path}")

    print("")
    print(f"  {BOLD}Próximo paso:{W} reinicia Frigate para aplicar los cambios:")
    print(f"  → docker restart frigate")
    print(f"  → Luego abre http://localhost:5000 para ver las cámaras en vivo")
    print("")

if __name__ == "__main__":
    main()
