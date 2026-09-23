#!/usr/bin/env bash
# FreeCAD Proxmox Manager — Community-Scripts-konformer Installer
# Einzeiler (auf dem Proxmox-HOST als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)"
# Varianten:
#   .../freecad.sh -- --vmid 200 --cpu 4 --ram 8192 --disk 30 --gpu virtio-gl
#   .../freecad.sh -- --lxc --ctid 150 --cpu 2 --ram 2048 --disk 8
#   .../freecad.sh -- --uninstall --vmid 200   |  -- --uninstall --lxc --ctid 150
#   .../freecad.sh -- --payload-only --freecad-version 1.1.3   (direkt im Gast/VM laufen lassen)
# Debug bei Fehlern: bash -x -c "$(wget -qLO - .../freecad.sh)" -- --debug
set -euo pipefail

# ================= Variablen (oben, anpassbar) =================
APP_NAME="freecad"
APP_PORT="8080"
DESKTOP_PORT="6080"
MODE="vm"                    # vm (empfohlen: GUI+GPU) | lxc (nur Manager+Headless)
CTID="150"
VMID="200"
HOSTNAME="freecad"
CPU="4"
RAM="8192"                   # MB (FreeCAD braucht RAM; LXC-Fallback: 2048)
DISK="30"                    # GB (FreeCAD AppImage + Desktop; LXC: 8 reicht)
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
BRIDGE="vmbr0"
GPU_MODE="virtio-gl"         # none | virtio-gl | passthrough | vgpu
VM_ISO="local:iso/debian-12-netinst.iso"
CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
CLOUD_IMG="debian-12-generic-amd64.qcow2"
CIUSER="root"                # Cloud-Init Login-User in der VM
CIPASS="freecad"             # Cloud-Init Passwort (nach Install ändern!)
FREECAD_VERSION="1.1.3"      # system | 1.0.1 | 1.1.2 | 1.1.3 | weekly
GITHUB_USER="HatchetMan111"
GITHUB_REPO="FreeCADProxmox"
GITHUB_BRANCH="main"
GITHUB_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
UNINSTALL=0
PAYLOAD_ONLY=0
DEBUG=0

# ================= Farben/Logging =================
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; N="\033[0m"
log(){ echo -e "${B}[${APP_NAME}]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }
die(){ echo -e "${R}[FEHLER]${N} $*" >&2; exit 1; }

# Komplette Fehlermeldungskette (niemals nur letzte Zeile)
on_err(){
  local ec=$? line=${1:-?} cmd=${2:-?}
  echo -e "${R}========== FEHLERKETTE ==========${N}" >&2
  echo "Exit-Code : $ec" >&2
  echo "Zeile     : $line" >&2
  echo "Kommando  : $cmd" >&2
  echo "--- Stack (caller) ---" >&2
  local i=0; while caller $i >&2; do i=$((i+1)); done || true
  echo "--- stdout/stderr-Kontext ---" >&2
  echo "MODE=$MODE CTID=$CTID VMID=$VMID GPU=$GPU_MODE" >&2
  echo "--- Host-Infos ---" >&2
  pveversion 2>&1 | head -5 >&2 || true
  if [[ "$MODE" == "lxc" ]]; then pct status "$CTID" 2>&1 >&2 || true
  else qm status "$VMID" 2>&1 >&2 || true; fi
  echo "Tipp: erneut mit Debug laufen lassen:" >&2
  echo "  bash -x -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\" -- --debug" >&2
  echo -e "${R}=================================${N}" >&2
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

usage(){
  cat <<EOF
$APP_NAME Installer (Proxmox VE Community-Scripts-Stil)

  bash -c "\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)"

Optionen:
  --vm                 KVM-VM anlegen (Default, empfohlen für FreeCAD-GUI/GPU)
  --lxc                statt VM einen LXC anlegen (nur Manager + Headless)
  --ctid ID            LXC-ID (Default $CTID)
  --vmid ID            VM-ID (Default $VMID)
  --cpu N              vCPUs (Default $CPU)
  --ram MB             RAM in MB (Default $RAM)
  --disk GB            Disk in GB (Default $DISK)
  --storage S          Storage (Default $STORAGE)
  --bridge B           Bridge (Default $BRIDGE)
  --gpu MODE           none|virtio-gl|passthrough|vgpu (Default $GPU_MODE)
  --freecad-version V  system|1.0.1|1.1.2|1.1.3|weekly (Default $FREECAD_VERSION)
  --iso ISO            Debian-ISO (Storage:Pfad) als Fallback wenn Cloud-Image scheitert (Default $VM_ISO)
  --ciuser USER        Cloud-Init Login-User (Default $CIUSER)
  --cipass PASS        Cloud-Init Passwort (Default: gesetzt, nach Install ändern!)
  --payload-only       nur Gast-Installation (in VM/LXC direkt ausführen)
  --uninstall          Container/VM entfernen
  --debug              set -x + volle Logs
  -h|--help            Hilfe

  Hinweis: Ist CTID/VMID belegt, nimmt das Script automatisch die nächste
  freie ID (kein Überschreiben, kein Abbruch). Eigene FreeCAD-VMs
  (Name freecad) werden wiederverwendet statt neu gebaut.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) MODE="vm"; shift;;
    --lxc) MODE="lxc"; shift;;
    --ctid) CTID="$2"; shift 2;;
    --vmid) VMID="$2"; shift 2;;
    --cpu) CPU="$2"; shift 2;;
    --ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --gpu) GPU_MODE="$2"; shift 2;;
    --freecad-version) FREECAD_VERSION="$2"; shift 2;;
    --iso) VM_ISO="$2"; shift 2;;
    --ciuser) CIUSER="$2"; shift 2;;
    --cipass) CIPASS="$2"; shift 2;;
    --payload-only) PAYLOAD_ONLY=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unbekannte Option: $1 (siehe --help)";;
  esac
done
[[ "$DEBUG" == "1" ]] && set -x

# ================= VM-Helfer (IDs, Guest-Agent) =================
VM_REUSE=0
# Eigene VM wiederverwenden, fremd belegte ID -> nächste freie (qm+pct teilen ID-Raum)
resolve_vmid(){
  VM_REUSE=0
  if qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; then
    if qm config "$VMID" 2>/dev/null | grep -qE "^name: ${HOSTNAME}$"; then
      VM_REUSE=1
      log "VM $VMID ist unsere eigene ($HOSTNAME) — wiederverwenden (kein Neuaufbau)."
      return 0
    fi
    warn "ID $VMID ist belegt (VM oder CT) – nehme automatisch die nächste freie ID."
    while qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; do VMID=$((VMID+1)); done
    log "Neue VMID: $VMID"
  fi
}
# Cloud-Init-Snippet: qemu-guest-agent installieren+starten (Debian-Images haben ihn oft nicht)
ensure_agent_snippet(){
  local store snipfile hostpath
  store=$(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}' || true)
  [[ -z "$store" ]] && store="local"
  snipfile="fc-agent-${VMID}.yaml"
  hostpath=$(pvesm path "${store}:snippets/${snipfile}" 2>/dev/null || true)
  if [[ -z "$hostpath" ]]; then
    warn "Snippet-Storage ${store} liefert keinen Pfad — weiter ohne Cloud-Init-Snippet (Agent-Kanal bleibt aktiv)."
    return 0
  fi
  mkdir -p "$(dirname "$hostpath")"
  cat > "$hostpath" <<'YAML'
#cloud-config
# Stellt sicher, dass der QEMU Guest Agent läuft (Installer braucht ihn für Payload + IP).
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
YAML
  if qm set "$VMID" --cicustom "user=${store}:snippets/${snipfile}"; then
    ok "Cloud-Init-Snippet gesetzt (${store}:snippets/${snipfile} → qemu-guest-agent)."
  else
    warn "cicustom konnte nicht gesetzt werden — weiter ohne Snippet."
    return 0
  fi
  qm cloudinit update "$VMID" >/dev/null 2>&1 || true
}
# Auf Guest-Agent warten; bei Fehlschlag volle Diagnose + Optionen, Return 1
wait_guest_agent(){
  log "Warte auf Guest-Agent (bis ~5 Min)…"
  local i ping_err=""
  for i in $(seq 1 60); do
    if ping_err=$(qm guest cmd "$VMID" ping 2>&1); then
      return 0
    fi
    sleep 5
    [[ $((i % 6)) -eq 0 ]] && log "… warte noch (Versuch $i/60)"
  done
  warn "Guest-Agent antwortet nicht."
  echo "--- Diagnose ---"
  qm status "$VMID" 2>&1 || true
  echo "--- qm config (ohne Passwort) ---"
  qm config "$VMID" 2>/dev/null | grep -v cipassword || true
  echo "--- letzter ping-Fehler ---"
  echo "$ping_err" | tail -5
  echo ""
  echo "Weiter mit einer Option:"
  echo "  A) Agent in der VM-Konsole nachinstallieren (Proxmox-WebUI -> VM $VMID -> Konsole, Login $CIUSER):"
  echo "       apt-get update && apt-get install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent"
  echo "     Danach Installer erneut laufen lassen (VM $VMID wird wiederverwendet, kein Neuaufbau)."
  echo "  B) Neu aufbauen (Cloud-Init installiert den Agent jetzt automatisch):"
  echo "       bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\" -- --uninstall --vmid $VMID"
  echo "       bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\""
  echo "  C) Ganz manuell in der VM (ohne Agent):"
  echo "     bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\" -- --payload-only --freecad-version ${FREECAD_VERSION}"
  return 1
}

# ================= Gast-Payload (idempotent, läuft in LXC *und* VM/Debian) =================
# fetch_fresh: GitHub-raw mit Retry gegen CDN-Staleness (Marker muss in Datei stehen)
fetch_fresh(){
  local dest="$1" path="$2" marker="$3" i
  for i in 1 2 3 4 5; do
    wget -q -O "$dest" "${GITHUB_BASE}/${path}?cb=$(date +%s)-$i" 2>/dev/null || \
    wget -q -O "$dest" "${GITHUB_BASE}/${path}" 2>/dev/null || { sleep 3; continue; }
    if [[ -z "$marker" ]] || grep -q "$marker" "$dest" 2>/dev/null; then
      return 0
    fi
    echo "[payload] CDN liefert alte Version von $path (Versuch $i/5) — retry…"
    sleep 3
  done
  echo "[payload] WARNUNG: $path evtl. veraltet (Marker '$marker' fehlt nach 5 Versuchen)"
  return 0
}
payload_install(){
  set -euo pipefail
  # Schutz: Payload gehört in den GAST (VM/LXC) — niemals auf dem Proxmox-Host ausführen!
  if [[ -d /etc/pve ]] && (command -v qm >/dev/null 2>&1 || command -v pct >/dev/null 2>&1); then
    echo "[FEHLER] --payload-only läuft IN DER VM / IM LXC (Gast), nicht auf dem Proxmox-Host!" >&2
    echo "Richtig: Proxmox-WebUI -> VM-Konsole (oder ssh root@<VM-IP>), dort als root ausführen." >&2
    echo "Oder alles automatisch: Einzeiler OHNE --payload-only auf dem Host starten." >&2
    exit 2
  fi
  echo "[freecad-payload] Starte Gast-Installation (Version: ${FREECAD_VERSION}, Port: ${APP_PORT})"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 python3-venv python3-pip wget curl fuse libfuse2 mesa-utils libxcb-cursor0 \
    xfce4 xfce4-terminal xdg-utils hicolor-icon-theme dbus-x11 2>&1 | tail -5 || true

  # FreeCAD: apt (system) oder AppImage aus github.com/FreeCAD/FreeCAD/releases
  mkdir -p /opt/freecad /opt/freecad-manager
  if [[ "${FREECAD_VERSION}" == "system" ]]; then
    apt-get install -y freecad freecad-common calculix-ccx || echo "[payload] apt-freecad schlug fehl, weiter mit Manager"
  else
    case "${FREECAD_VERSION}" in
      1.0.1) AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.0.1/FreeCAD_1.0.1-conda-Linux-x86_64-py311.AppImage";;
      1.1.2) AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.1.2/FreeCAD_1.1.2-Linux-x86_64-py311.AppImage";;
      1.1.3) AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.1.3/FreeCAD_1.1.3-Linux-x86_64-py311.AppImage";;
      weekly) AI_URL="https://github.com/FreeCAD/FreeCAD-Bundle/releases/download/weekly-builds/FreeCAD_Linux-x86_64-py311.AppImage";;
      *) echo "[payload] Unbekannte Version ${FREECAD_VERSION}, nutze 1.1.3"
         AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.1.3/FreeCAD_1.1.3-Linux-x86_64-py311.AppImage";;
    esac
    if [[ ! -s /opt/freecad/FreeCAD.AppImage ]]; then
      if wget -O /opt/freecad/FreeCAD.AppImage -c "$AI_URL"; then
        chmod +x /opt/freecad/FreeCAD.AppImage
      else
        echo "[payload] AppImage-Download 404/Fehler — Fallback: apt freecad (Manager läuft trotzdem)"
        rm -f /opt/freecad/FreeCAD.AppImage
        apt-get install -y freecad freecad-common || echo "[payload] apt-freecad schlug fehl, weiter mit Manager"
      fi
    else
      echo "[payload] AppImage existiert bereits, überspringe Download (idempotent)"
      chmod +x /opt/freecad/FreeCAD.AppImage
    fi
    # Headless-Alias für Manager (freecadcmd aus AppImage extrahieren scheitert oft ohne FUSE -> Fallback apt freecadcmd)
    apt-get install -y freecadcmd 2>/dev/null || apt-get install -y freecad 2>/dev/null || true
  fi

  # FreeCAD vollautomatisch fertig installieren (kein Klick im UI nötig):
  # Smoke-Test, FUSE-freier Extract-Fallback, /usr/local/bin/freecad, .desktop für XFCE
  if [[ -s /opt/freecad/FreeCAD.AppImage ]]; then
    if /opt/freecad/FreeCAD.AppImage --appimage-extract-and-run --version >/dev/null 2>&1; then
      echo "[payload] FreeCAD-AppImage läuft (FUSE OK)."
    else
      echo "[payload] Direktstart scheitert (FUSE?) — extrahiere AppImage (läuft ohne FUSE)…"
      (cd /opt/freecad && ./FreeCAD.AppImage --appimage-extract >/dev/null 2>&1) || echo "[payload] Extract-Warnung, versuche weiter"
    fi
    if [[ -x /opt/freecad/squashfs-root/AppRun ]]; then
      printf '#!/bin/sh\nexec /opt/freecad/squashfs-root/AppRun "$@"\n' > /usr/local/bin/freecad
    else
      printf '#!/bin/sh\nexec /opt/freecad/FreeCAD.AppImage --appimage-extract-and-run "$@"\n' > /usr/local/bin/freecad
    fi
    chmod +x /usr/local/bin/freecad
    QT_QPA_PLATFORM=offscreen freecad --version 2>&1 | head -2 || echo "[payload] FreeCAD-Versionscheck Warnung (headless normal, läuft trotzdem im Desktop)"
    cat > /usr/share/applications/freecad.desktop <<'DESKTOP_EOF'
[Desktop Entry]
Name=FreeCAD
Exec=/usr/local/bin/freecad %F
Icon=freecad
Type=Application
Categories=Graphics;Engineering;
DESKTOP_EOF
    echo "[payload] FreeCAD bereit: $(command -v freecad)"
  fi
  # FreeCAD auf Desktop + Autostart (egal ob AppImage oder apt): Icon, Autostart, Menü-Refresh
  if command -v freecad >/dev/null 2>&1; then
    FC_BIN="$(command -v freecad)"
    mkdir -p /root/Desktop /root/.config/autostart
    cat > /root/Desktop/FreeCAD.desktop <<DESKTOP2_EOF
[Desktop Entry]
Name=FreeCAD
Exec=$FC_BIN %F
Icon=freecad
Type=Application
Categories=Graphics;Engineering;
DESKTOP2_EOF
    chmod +x /root/Desktop/FreeCAD.desktop
    # Als vertrauenswürdig markieren (sonst startet XFCE es nicht per Doppelklick)
    gio set /root/Desktop/FreeCAD.desktop metadata::trusted true 2>/dev/null || true
    # Autostart beim Desktop-Login (löschen zum Deaktivieren: rm /root/.config/autostart/freecad.desktop)
    cp /root/Desktop/FreeCAD.desktop /root/.config/autostart/freecad.desktop
    update-desktop-database /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
    echo "[payload] FreeCAD-Icon auf Desktop + Autostart aktiv ($FC_BIN)."
  else
    echo "[payload] WARNUNG: kein freecad-Binary gefunden (weder AppImage noch apt)!"
  fi

  # Standard-Addon: FreeCAD Robust MCP Suite (KI-Assistenten via MCP an FreeCAD, 150+ Tools)
  # - Workbench "Robust MCP Bridge" (Addon-Manager-Paket, Bridge auf Port 9875/xmlrpc)
  # - PyPI-Serverpaket freecad-robust-mcp (Import: freecad_mcp)
  # Doku: https://spkane.github.io/freecad-addon-robust-mcp-server/latest/
  echo "[payload] Installiere Robust-MCP-Addon (Standard)…"
  apt-get install -y git 2>&1 | tail -1 || echo "[payload] git-Install Warnung"
  mkdir -p /root/.FreeCAD/Mod
  if [[ -d /root/.FreeCAD/Mod/freecad-addon-robust-mcp-server/.git ]]; then
    # Eigener Bind-Patch vorher zurücknehmen, sonst blockiert er git pull
    (cd /root/.FreeCAD/Mod/freecad-addon-robust-mcp-server && git checkout -- freecad/RobustMCPBridge/freecad_mcp_bridge/blocking_bridge.py 2>/dev/null; git pull --ff-only 2>&1 | tail -2) || echo "[payload] MCP-Addon-Update übersprungen"
  else
    rm -rf /root/.FreeCAD/Mod/freecad-addon-robust-mcp-server
    git clone --depth 1 https://github.com/spkane/freecad-addon-robust-mcp-server.git /root/.FreeCAD/Mod/freecad-addon-robust-mcp-server 2>&1 | tail -2 \
      || echo "[payload] MCP-Addon-Clone fehlgeschlagen (weiter ohne Workbench)"
  fi
  pip3 install --break-system-packages -q freecad-robust-mcp 2>&1 | tail -2 || echo "[payload] pip freecad-robust-mcp Warnung"
  python3 -c "import freecad_mcp; print('[payload] MCP-Serverpaket OK')" 2>&1 | tail -1 || echo "[payload] MCP-Importcheck Warnung"
  [[ -f /root/.FreeCAD/Mod/freecad-addon-robust-mcp-server/package.xml ]] \
    && echo "[payload] MCP-Workbench OK: Robust MCP Bridge (FreeCAD: Workbench wählen -> Start Bridge, Port 9875)."
  # Headless-MCP-Bridge als Service (DAS soll laufen!): FreeCADCmd + blocking_bridge.py -> :9875 xmlrpc, :9876 socket
  # Doku: https://spkane.github.io/freecad-addon-robust-mcp-server/latest/getting-started/quickstart/ (Option B)
  echo "[payload] Richte Headless-MCP-Bridge ein (freecad-mcp.service)…"
  MCP_FCCMD=""
  for c in /opt/freecad/squashfs-root/usr/bin/FreeCADCmd /usr/bin/freecadcmd; do
    if [[ -x "$c" ]]; then MCP_FCCMD="$c"; break; fi
  done
  [[ -z "$MCP_FCCMD" ]] && MCP_FCCMD="$(command -v freecadcmd || true)"
  MCP_BRIDGE="/root/.FreeCAD/Mod/freecad-addon-robust-mcp-server/freecad/RobustMCPBridge/freecad_mcp_bridge/blocking_bridge.py"
  # Bridge-Bind: Upstream default localhost -> 0.0.0.0 (sonst nur im Gast erreichbar!). Nur LAN, keine Auth!
  if grep -q 'host="localhost"' "$MCP_BRIDGE" 2>/dev/null; then
    sed -i 's/host="localhost"/host="0.0.0.0"/' "$MCP_BRIDGE" && echo "[payload] Bridge-Bind: 0.0.0.0 (LAN, ohne Auth — nur vertrauenswürdiges Netz!)."
  elif grep -q 'host="0.0.0.0"' "$MCP_BRIDGE" 2>/dev/null; then
    echo "[payload] Bridge-Bind bereits 0.0.0.0."
  else
    echo "[payload] Hinweis: host-Zeile upstream geändert — Bridge evtl. nur localhost."
  fi
  # XDG-Mod-Pfad zusätzlich verlinken (FreeCAD 1.x sucht auch dort — hilft GUI-Dropdown ebenfalls)
  mkdir -p /root/.local/share/FreeCAD
  ln -sfn /root/.FreeCAD/Mod /root/.local/share/FreeCAD/Mod
  if [[ -n "$MCP_FCCMD" && -x "$MCP_FCCMD" && -f "$MCP_BRIDGE" ]]; then
    cat > /etc/systemd/system/freecad-mcp.service <<MCP_EOF
[Unit]
Description=FreeCAD Robust MCP Bridge (headless, :9875 xmlrpc / :9876 socket)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$MCP_FCCMD $MCP_BRIDGE
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
MCP_EOF
    systemctl daemon-reload
    systemctl enable freecad-mcp.service || true
    systemctl restart freecad-mcp.service
    sleep 8
    if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -qE ':(9875|9876) '; then
      echo "[payload] MCP-Bridge lauscht (:9875 xmlrpc / :9876 socket) mit $MCP_FCCMD."
    else
      echo "[payload] WARNUNG: MCP-Bridge antwortet (noch?) nicht — Status:"
      systemctl status freecad-mcp.service --no-pager 2>&1 | head -12 || true
      journalctl -u freecad-mcp.service -n 20 --no-pager 2>&1 | tail -12 || true
    fi
  else
    echo "[payload] WARNUNG: MCP-Bridge übersprungen (FreeCADCmd: '${MCP_FCCMD:-fehlt}', Bridge-Datei: $MCP_BRIDGE)"
  fi
  # Workbench-Verifikation: Dateien + lädt 1.1.3 sie? (FreeCAD.log der letzten GUI-Sitzung prüfen)
  echo "[payload] Workbench-Dateien: $(ls /root/.FreeCAD/Mod/ 2>/dev/null | tr '\n' ' ')"
  grep -il "robust" /root/.FreeCAD/FreeCAD.log 2>/dev/null && echo "[payload] FreeCAD.log kennt Robust (Workbench wurde geladen)." || echo "[payload] Hinweis: FreeCAD nach Install NEU STARTEN (Workbenches nur beim Start eingelesen), dann Dropdown prüfen."
  # KasmVNC für Browser-Desktop (:6080) — Version dynamisch via GitHub-API (feste URLs veralten!)
  if ! command -v kasmvncserver >/dev/null 2>&1; then
    echo "[payload] Installiere KasmVNC…"
    KASMVNC_DEB_URL=""
    KASMVNC_API=$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest 2>/dev/null || wget -qO- https://api.github.com/repos/kasmtech/KasmVNC/releases/latest 2>/dev/null || true)
    KASMVNC_DEB_URL=$(echo "$KASMVNC_API" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*bookworm[^"]*amd64\.deb"' | head -1 | grep -oE 'https://[^"]+' || true)
    [[ -z "$KASMVNC_DEB_URL" ]] && KASMVNC_DEB_URL="https://github.com/kasmtech/KasmVNC/releases/download/v1.5.0/kasmvncserver_bookworm_1.5.0_amd64.deb"
    echo "[payload] KasmVNC-URL: $KASMVNC_DEB_URL"
    if (wget -O /tmp/kasmvnc.deb -c "$KASMVNC_DEB_URL" || curl -fSL -o /tmp/kasmvnc.deb -C - "$KASMVNC_DEB_URL") && apt-get install -y /tmp/kasmvnc.deb; then
      echo "[payload] KasmVNC OK: $(command -v kasmvncserver)"
    else
      echo "[payload] KasmVNC-Install fehlgeschlagen (Manager läuft trotzdem, Desktop später via Manager-UI nachholbar)"
    fi
  else
    echo "[payload] KasmVNC bereits vorhanden: $(command -v kasmvncserver)"
  fi
  # KasmVNC-Write-User non-interaktiv vorbelegen (verhindert First-Run-Wizard;
  # falls vncpasswd ein TTY erzwingt, beantwortet der Service den Wizard per stdin).
  # Login: freecad/freecad — mit -disableBasicAuth im Service ist der Desktop im LAN direkt offen!
  if command -v vncpasswd >/dev/null 2>&1; then
    printf 'freecad\nfreecad\n' | vncpasswd -u freecad -r -w >/dev/null 2>&1 \
      && echo "[payload] KasmVNC-User freecad angelegt." \
      || echo "[payload] vncpasswd-Vorbelegung übersprungen (Wizard-Antwort via Service-Stdin aktiv)"
  fi
  # Eigene xstartup-Datei (deterministisch, kein DE-Prompt; -select-de würde sie überschreiben)
  mkdir -p /root/.vnc
  cat > /root/.vnc/xstartup-freecad <<'XSTARTUP_EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec /usr/bin/startxfce4
XSTARTUP_EOF
  chmod +x /root/.vnc/xstartup-freecad
  echo "[payload] KasmVNC-Session: -xstartup /root/.vnc/xstartup-freecad"

  # Manager-App + venv von GitHub (Fallback: bereits vorhandene main.py behalten = idempotent)
  if [[ ! -s /opt/freecad-manager/main.py ]] || [[ "${FORCE_REFETCH:-0}" == "1" ]]; then
    fetch_fresh /opt/freecad-manager/main.py app/main.py "FreeCAD Proxmox Manager" || echo "[payload] GitHub-Fetch fehlgeschlagen, nutze vorhandene main.py"
  fi
  fetch_fresh /opt/freecad-manager/requirements.txt app/requirements.txt "fastapi" || true
  if [[ ! -x /opt/freecad-manager/venv/bin/python ]]; then
    python3 -m venv /opt/freecad-manager/venv
  fi
  /opt/freecad-manager/venv/bin/pip install -q -r /opt/freecad-manager/requirements.txt || \
    /opt/freecad-manager/venv/bin/pip install -q fastapi 'uvicorn[standard]' python-multipart

  fetch_fresh /etc/systemd/system/freecad.service systemd/freecad.service "WantedBy=multi-user.target" || echo "[payload] service-fetch fehlgeschlagen"
  fetch_fresh /etc/systemd/system/freecad-desktop.service systemd/freecad-desktop.service "xstartup-freecad" || echo "[payload] desktop-service-fetch fehlgeschlagen"
  systemctl daemon-reload
  systemctl enable freecad.service freecad-desktop.service || true
  systemctl restart freecad.service
  # Alte verwaiste Xvnc-Prozesse (:99) killen — sonst blockieren sie den Neustart (Display belegt)
  systemctl stop freecad-desktop.service 2>/dev/null || true
  kasmvncserver -kill :99 2>/dev/null || true
  pkill -f "Xvnc :99" 2>/dev/null || true
  # Alte FreeCAD-Prozesse killen (sonst läuft evtl. apt-0.20 ohne neue Workbenches weiter)
  pkill -f "squashfs-root.*FreeCAD" 2>/dev/null || true
  pkill -f "FreeCAD.AppImage" 2>/dev/null || true
  pkill -x FreeCAD 2>/dev/null || true
  # apt-Desktop-Datei entfernen — nur UNSER Icon (AppImage 1.1.3) soll im Menü sein (keine 0.20-Doppelgänger)
  rm -f /usr/share/applications/org.freecad.FreeCAD.desktop /usr/share/applications/freecad-0.20.desktop 2>/dev/null || true
  sleep 2
  rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  # Desktop nur starten wenn kasmvnc da ist, sonst läuft Manager trotzdem
  systemctl restart freecad-desktop.service || echo "[payload] Desktop-Service wartet auf KasmVNC (Manager läuft trotzdem)"

  # ---- Verifikation (Service + HTTP) ----
  echo "[payload] Verifiziere…"
  systemctl is-active freecad.service
  for i in 1 2 3 4 5 6; do
    if curl -fsS "http://localhost:${APP_PORT}/healthz" >/dev/null 2>&1; then
      echo "[payload] Web UI antwortet (Versuch $i)."
      break
    fi
    echo "[payload] Warte auf Web UI… Versuch $i/6"; sleep 5
    if [[ "$i" == "6" ]]; then
      echo "=========== VOLLSTÄNDIGE FEHLERKETTE (Web UI antwortet nicht) ==========="
      systemctl status freecad.service --no-pager || true
      journalctl -u freecad.service -n 100 --no-pager || true
      ss -tlnp 2>/dev/null | head -20 || netstat -tlnp 2>/dev/null | head -20 || true
      exit 1
    fi
  done
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "Fertig! Manager: http://${IP}:${APP_PORT}  |  Desktop (KasmVNC, https!): https://${IP}:${DESKTOP_PORT}"
  # ---- Desktop-Port prüfen (Warnung, kein Abbruch — Manager ist das Pflichtziel) ----
  sleep 12  # KasmVNC braucht Anlaufzeit (Zertifikate, Xvnc) — sonst false-Warnung
  if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -q ":${DESKTOP_PORT} "; then
    echo "[payload] Desktop-Port ${DESKTOP_PORT} lauscht."
  else
    echo "[payload] WARNUNG: nichts auf Port ${DESKTOP_PORT} — Desktop-Status:"
    systemctl status freecad-desktop.service --no-pager 2>&1 | head -12 || true
    journalctl -u freecad-desktop.service -n 20 --no-pager 2>&1 | tail -12 || true
  fi
}

if [[ "$PAYLOAD_ONLY" == "1" ]]; then
  payload_install
  exit 0
fi

# ================= Host-Seite (Proxmox) =================
[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct >/dev/null 2>&1 || command -v qm >/dev/null 2>&1 || die " Weder pct noch qm gefunden — auf dem Proxmox-Host ausführen."
command -v wget >/dev/null 2>&1 || { apt-get update && apt-get install -y wget curl; }
command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y curl; }
command -v curl >/dev/null 2>&1 || die "curl fehlt auf dem Host und konnte nicht installiert werden (Health-Checks brauchen curl)."

if [[ "$UNINSTALL" == "1" ]]; then
  log "Deinstalliere… (MODE=$MODE)"
  if [[ "$MODE" == "lxc" ]]; then
    pct stop "$CTID" || true; pct destroy "$CTID" || true; ok "LXC $CTID entfernt."
  else
    qm stop "$VMID" || true; qm destroy "$VMID" --purge || qm destroy "$VMID" || true; ok "VM $VMID entfernt."
  fi
  exit 0
fi

log "Modus: $MODE (CPU=$CPU RAM=${RAM}MB Disk=${DISK}GB GPU=$GPU_MODE FreeCAD=$FREECAD_VERSION)"
log "Quelle: $GITHUB_BASE (FreeCAD-Upstream: https://github.com/FreeCAD/FreeCAD/releases)"

# ---------- LXC-Pfad (leichtgewichtig: Manager + Headless, kein echtes Desktop-GPU) ----------
if [[ "$MODE" == "lxc" ]]; then
  warn "LXC kann kein echtes vGPU/PCIe-Passthrough für FreeCAD-GUI — für volle Leistung VM-Modus nehmen."
  pveam update || true
  # Neuestes Debian-12-Template dynamisch (feste Versionen verschwinden von den Mirrors!)
  NEWEST_TPL=$(pveam available --section system 2>/dev/null | grep -oE 'debian-12-standard_[0-9.-]+_amd64\.tar\.zst' | sort -V | tail -1 || true)
  [[ -n "$NEWEST_TPL" ]] && TEMPLATE="$NEWEST_TPL"
  log "Template: $TEMPLATE"
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$(basename $TEMPLATE .tar.zst | head -c 20)"; then
    log "Lade Template $TEMPLATE…"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || die "Template-Download fehlgeschlagen"
  fi
  # ------ Belegte CTID -> automatisch nächste freie nehmen (kein Abbruch, kein Überschreiben) -----
  # VMs und CTs teilen einen ID-Raum -> immer BEIDE prüfen!
  if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then
    warn "ID $CTID ist belegt (CT oder VM) – nehme automatisch die nächste freie ID."
    while pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; do CTID=$((CTID+1)); done
    log "Neue CTID: $CTID"
  fi
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" --cores "$CPU" --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" --net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
    --onboot 1 --unprivileged 1 --features nesting=1
  ok "CT $CTID erstellt."
  # /dev/dri-Passthrough versuchen (Auto), sonst Warnung + README-Pfad
  if [[ "$GPU_MODE" == "passthrough" ]]; then
    if [[ -e /dev/dri/card0 ]]; then
      pct set "$CTID" --dev0 /dev/dri/card0 || warn "dev0 konnte nicht gesetzt werden"
      [[ -e /dev/dri/renderD128 ]] && pct set "$CTID" --dev1 /dev/dri/renderD128 || true
      ok "/dev/dri durchgereicht."
    else
      warn "Kein /dev/dri auf Host — kein Auto-Passthrough möglich. Siehe README §4 (manuell)."
    fi
  fi
  pct start "$CTID" || true
  sleep 5
  log "Installiere Payload in CT $CTID…"
  pct exec "$CTID" -- bash -c "FREECAD_VERSION=$FREECAD_VERSION APP_PORT=$APP_PORT DESKTOP_PORT=$DESKTOP_PORT GITHUB_BASE=$GITHUB_BASE bash -c \"\$(wget -qLO - $GITHUB_BASE/install/freecad.sh?cb=\$(date +%s))\" -- --payload-only --freecad-version $FREECAD_VERSION"
  pct exec "$CTID" -- systemctl is-active freecad.service
  pct exec "$CTID" -- curl -fsS "http://localhost:${APP_PORT}/healthz"
  CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
  ok "Service läuft, Web UI antwortet."
  echo "Fertig! Web UI: http://${CT_IP}:${APP_PORT}  (Desktop in LXC nur Headless — für GUI VM-Modus nehmen)"
  exit 0
fi

# ---------- VM-Pfad (empfohlen für FreeCAD) ----------
# ------ Belegte VMID -> automatisch nächste freie nehmen (kein Abbruch, kein Überschreiben) -----
# VMs und CTs teilen einen ID-Raum -> immer BEIDE prüfen (qm + pct)!
resolve_vmid

# Helper: Befehl im Gast via Guest-Agent (probiert erst mit, dann ohne "--")
guest_exec(){
  if qm guest exec "$VMID" -- "$@" >/dev/null 2>&1; then return 0; fi
  qm guest exec "$VMID" "$@"
}
# Wie guest_exec, aber Ausgabe immer sichtbar (Fortschritt/Diagnose, nie schlucken)
guest_exec_show(){
  local out=""
  if out=$(qm guest exec "$VMID" -- "$@" 2>/dev/null); then echo "$out"; return 0; fi
  qm guest exec "$VMID" "$@"
}
# qga: Gast-Befehl ausführen, QGA-JSON-Hülle (out-data/err-data base64) dekodieren,
# dekodierte Ausgabe drucken und GAST-Exit-Code zurückgeben (nicht den von qm!).
qga(){
  local raw ec
  if raw=$(qm guest exec "$VMID" -- "$@" 2>/dev/null); then :;
  elif raw=$(qm guest exec "$VMID" "$@" 2>/dev/null); then :;
  else echo "(guest exec fehlgeschlagen)"; return 1; fi
  ec=$(echo "$raw" | grep -oE '"exitcode"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  if echo "$raw" | python3 -c "
import json,sys,base64
d=json.load(sys.stdin)
out=d.get('out-data',''); err=d.get('err-data','')
if out: sys.stdout.write(base64.b64decode(out).decode('utf-8','replace'))
if err: sys.stderr.write(base64.b64decode(err).decode('utf-8','replace'))
" 2>/dev/null; then
    return "${ec:-0}"
  fi
  echo "$raw"
  return "${ec:-0}"
}

# OS-Disk: Debian-Cloud-Image laden + importieren (vollautomatisch, inkl. Cloud-Init).
# Fallback: vorhandene Debian-ISO als CDROM einhängen (dann manuell installieren).
vm_attach_os(){
  local img_dir="/var/lib/vz/template/iso"
  local img_file="${img_dir}/${CLOUD_IMG}"
  mkdir -p "$img_dir"
  if [[ ! -s "$img_file" ]]; then
    log "Lade Debian-Cloud-Image (~300 MB)…"
    if ! wget -O "$img_file" -c "$CLOUD_IMG_URL" 2>&1 | tail -2; then
      warn "Cloud-Image-Download fehlgeschlagen — versuche curl…"
      curl -fSL -o "$img_file" -C - "$CLOUD_IMG_URL" || rm -f "$img_file"
    fi
  else
    log "Cloud-Image bereits vorhanden (idempotent, kein Re-Download)."
  fi
  if [[ -s "$img_file" ]]; then
    log "Importiere Cloud-Image nach $STORAGE…"
    local out diskname
    out=$(qm importdisk "$VMID" "$img_file" "$STORAGE" 2>&1) || {
      echo "$out" >&2
      warn "importdisk fehlgeschlagen — nutze ISO-Fallback."
      vm_attach_iso_fallback
      return 0
    }
    echo "$out" | tail -3
    diskname=$(echo "$out" | grep -oE "vm-${VMID}-disk-[0-9]+" | tail -1)
    [[ -z "$diskname" ]] && diskname="vm-${VMID}-disk-1"
    qm set "$VMID" --scsi0 "${STORAGE}:${diskname}"
    qm resize "$VMID" scsi0 "${DISK}G" || warn "resize auf ${DISK}G fehlgeschlagen (weiter mit Image-Größe)"
    qm set "$VMID" --boot c --bootdisk scsi0 \
      --ciuser "$CIUSER" --cipassword "$CIPASS" --ipconfig0 ip=dhcp
    ok "OS-Disk bereit: scsi0=${diskname} (${DISK}G), Cloud-Init: user=$CIUSER / dhcp."
  else
    warn "Kein Cloud-Image verfügbar — nutze ISO-Fallback."
    vm_attach_iso_fallback
  fi
}

vm_attach_iso_fallback(){
  local iso_path=""
  if command -v pvesm >/dev/null 2>&1; then
    iso_path=$(pvesm path "$VM_ISO" 2>/dev/null || true)
  fi
  [[ -z "$iso_path" ]] && iso_path="/var/lib/vz/template/iso/$(basename "$VM_ISO" | cut -d: -f2)"
  if [[ ! -f "$iso_path" ]]; then
    die "Weder Cloud-Image noch ISO gefunden. Lade eine Debian-12-netinst-ISO nach /var/lib/vz/template/iso/ und rufe erneut auf (nächste freie VMID wird automatisch genommen). Komplette Kette oben, Debug: bash -x … -- --debug"
  fi
  qm set "$VMID" --scsi0 "${STORAGE}:${DISK}" --ide0 "${VM_ISO},media=cdrom" --boot "order=ide0;scsi0"
  warn "ISO-Fallback: Debian manuell in der VM-Konsole installieren, danach in der VM ausführen:"
  warn "  bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\" -- --payload-only --freecad-version ${FREECAD_VERSION}"
  ISO_FALLBACK=1
}
ISO_FALLBACK=0

if [[ "$VM_REUSE" == "1" ]]; then
  log "Reuse: vorhandene eigene VM $VMID wird weiterverwendet (kein Neuaufbau)."
  qm set "$VMID" --agent enabled=1 --onboot 1 || true
else

log "Lege VM $VMID an (KVM, FreeCAD-GUI + GPU)…"
qm create "$VMID" --name "$HOSTNAME" --cores "$CPU" --memory "$RAM" \
  --net0 virtio,bridge="$BRIDGE" --scsihw virtio-scsi-pci \
  --ide2 "${STORAGE}:cloudinit" \
  --serial0 socket --vga serial0 \
  --agent enabled=1 --onboot 1 --ostype l26
ok "VM $VMID erstellt (Hülle)."
vm_attach_os

# GPU-Auto-Versuch (wenn nicht automatisch geht -> README §4, manueller vGPU-Weg)
case "$GPU_MODE" in
  virtio-gl)
    log "Installiere virtio-gl Host-Libs (fixt 'missing libraries for virtio-gl')…"
    (apt-get update && apt-get install -y libgl1 libegl1) 2>&1 | tail -2 || \
      warn "libgl1/libegl1 konnten nicht installiert werden — versuche virtio-gl trotzdem."
    if qm set "$VMID" --vga virtio-gl; then
      ok "GPU-Modus virtio-gl gesetzt (3D ohne Passthrough; reicht für FreeCAD-Browser-Desktop)."
    else
      warn "virtio-gl abgelehnt — falle auf Standard-VGA zurück (KasmVNC nutzt llvmpipe)."
      qm set "$VMID" --vga std || true
    fi
    ;;
  passthrough)
    if lspci -nn 2>/dev/null | grep -qi "nvidia\|amd.*vga"; then
      warn "PCIe-GPU gefunden — Auto-Passthrough erfordert IOMMU + Geräte-ID. Drucke Vorlage (manuell bestätigen):"
      lspci -nn | grep -iE "vga|3d|display" || true
      echo "  Beispiel: qm set $VMID --hostpci0 0000:01:00.0,pcie=1"
      echo "  IOMMU nötig: Intel 'intel_iommu=on iommu=pt' / AMD 'amd_iommu=on iommu=pt' in /etc/default/grub -> update-grub + reboot"
    else
      warn "Keine dedizierte GPU auf Host gefunden — VM startet mit virtio-gl/Standard-VGA. Für vGPU siehe README §4."
    fi
    ;;
  vgpu)
    warn "vGPU ist nie vollautomatisch — prüfe mdev-Typen und drucke Anleitung:"
    ls /sys/bus/pci/devices/*/mdev_supported_types 2>&1 || warn "Keine mdev-Typen (vGPU Manager fehlt? -> README §4)."
    echo "  Nach Host-Setup: qm set $VMID --hostpci0 0000:01:00.0,mdev=nvidia-11"
    echo "  Details: https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE (siehe README §4)"
    ;;
  none) log "GPU-Modus none — VM nutzt Standard-VGA + Software-Rendering (llvmpipe).";;
  *) warn "Unbekannter GPU-Modus $GPU_MODE — weiter mit Standard-VGA.";;
esac
fi

# Guest-Agent per Cloud-Init sicherstellen (Debian-Images haben ihn oft nicht aktiv)
ensure_agent_snippet
if qm status "$VMID" 2>/dev/null | grep -q running; then
  log "VM $VMID läuft bereits."
else
  qm start "$VMID"
  ok "VM $VMID gestartet (onboot: 1)."
fi

if [[ "$ISO_FALLBACK" == "1" ]]; then
  echo ""
  echo "================ MANUELL INSTALLIEREN (ISO-Fallback) ================"
  echo "1) Proxmox-WebUI -> VM $VMID -> Konsole -> Debian installieren."
  echo "2) In der VM (als root):"
  echo "     bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\" -- --payload-only --freecad-version ${FREECAD_VERSION}"
  echo "3) Danach: Manager http://<VM-IP>:${APP_PORT} | Desktop https://<VM-IP>:${DESKTOP_PORT} (Zertifikat akzeptieren)"
  echo "=============================================================="
  exit 0
fi

# Auf Guest-Agent warten (Cloud-Image bootet 1-3 Min), dann Payload im Hintergrund starten
wait_guest_agent || exit 1
ok "Guest-Agent antwortet."

log "Starte Gast-Payload im Hintergrund (Log in VM: /var/log/fc-payload.log)…"
guest_exec bash -c "(wget -qLO /tmp/fc.sh ${GITHUB_BASE}/install/freecad.sh || curl -fsSL -o /tmp/fc.sh ${GITHUB_BASE}/install/freecad.sh) && nohup bash /tmp/fc.sh --payload-only --freecad-version ${FREECAD_VERSION} > /var/log/fc-payload.log 2>&1 & echo gestartet" || \
  warn "Payload-Start via Guest-Agent fehlgeschlagen — manuell in der VM ausführen (Befehl oben)."

# Auf Web UI warten: Gast-IP via Agent ermitteln, von Host aus pollen
log "Warte auf Web UI (bis ~15 Min, AppImage ~800 MB)…"
# Gast-IP ermitteln: erst via Agent-Interfaces, Fallback via ip-Befehl im Gast
get_guest_ip(){
  local ip=""
  ip=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | head -1 || true)
  if [[ -z "$ip" ]]; then
    ip=$(qm guest exec "$VMID" -- ip -4 -o addr show 2>/dev/null | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
  fi
  if [[ -z "$ip" ]]; then
    ip=$(qm guest exec "$VMID" ip -4 -o addr show 2>/dev/null | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
  fi
  echo "$ip"
}
VM_IP=""
for i in $(seq 1 90); do
  if [[ -z "$VM_IP" ]]; then
    VM_IP=$(get_guest_ip || true)
    [[ -n "$VM_IP" ]] && log "Gast-IP: $VM_IP"
  fi
  if [[ -n "$VM_IP" ]] && curl -fsS "http://${VM_IP}:${APP_PORT}/healthz" >/dev/null 2>&1; then
    ok "Web UI antwortet."
    echo "Fertig! Manager: http://${VM_IP}:${APP_PORT}  |  Desktop (KasmVNC, https!): https://${VM_IP}:${DESKTOP_PORT}"
    echo "VM-Login (Cloud-Init): user=$CIUSER — Passwort bitte nach Install ändern!"
    exit 0
  fi
  sleep 10
  if [[ $((i % 6)) -eq 0 ]]; then
    log "… warte noch (Versuch $i/90)"
  fi
  # Alle ~2 Min: Fortschritt aus dem Gast zeigen (Payload-Log + Service-Status)
  if [[ $((i % 12)) -eq 0 ]]; then
    echo "--- Gast-Fortschritt (Versuch $i/90) ---"
    qga tail -n 5 /var/log/fc-payload.log || echo "(Payload-Log noch nicht lesbar)"
    qga systemctl is-active freecad.service || echo "(Manager-Service noch nicht aktiv)"
  fi
done
echo "=========== PAYLOAD-LOG (vollständig, aus der VM) ==========="
qga tail -n 100 /var/log/fc-payload.log || echo "(kein Payload-Log im Gast)"
echo "=========== SERVICE + PORTS (aus der VM) ==========="
qga systemctl status freecad.service --no-pager || true
qga ss -tlnp 2>/dev/null || qga netstat -tlnp || true
echo "=========== GAST-LOKALER CHECK (Netz vs. Service) ==========="
if qga curl -fsS -m 10 "http://localhost:${APP_PORT}/healthz"; then
  echo "-> Im Gast antwortet die Web UI, vom Host aber nicht: Routing/Firewall zwischen Host und Gast prüfen"
  echo "   (PVE Datacenter-Firewall? vmbr-Subnetz? Gast-IP $VM_IP vom Host aus pingbar? Teste: ping -c2 $VM_IP)"
else
  echo "-> Auch im Gast keine Antwort: Service-Problem — journal in der VM: journalctl -u freecad.service -n 100 --no-pager"
fi
die "Web UI antwortet nicht nach ~15 Min. Log oben prüfen; in der VM: journalctl -u freecad.service -n 100 --no-pager. Debug: bash -x … -- --debug"
