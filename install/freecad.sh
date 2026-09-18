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
  --payload-only       nur Gast-Installation (in VM/LXC direkt ausführen)
  --uninstall          Container/VM entfernen
  --debug              set -x + volle Logs
  -h|--help            Hilfe

  Hinweis: Ist CTID/VMID belegt, nimmt das Script automatisch die nächste
  freie ID (kein Überschreiben, kein Abbruch).
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
    --payload-only) PAYLOAD_ONLY=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unbekannte Option: $1 (siehe --help)";;
  esac
done
[[ "$DEBUG" == "1" ]] && set -x

# ================= Gast-Payload (idempotent, läuft in LXC *und* VM/Debian) =================
payload_install(){
  set -euo pipefail
  echo "[freecad-payload] Starte Gast-Installation (Version: ${FREECAD_VERSION}, Port: ${APP_PORT})"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 python3-venv python3-pip wget curl fuse libfuse2 mesa-utils \
    xfce4 xfce4-terminal xdg-utils hicolor-icon-theme dbus-x11 2>&1 | tail -5 || true

  # FreeCAD: apt (system) oder AppImage aus github.com/FreeCAD/FreeCAD/releases
  mkdir -p /opt/freecad /opt/freecad-manager
  if [[ "${FREECAD_VERSION}" == "system" ]]; then
    apt-get install -y freecad freecad-common calculix-ccx || echo "[payload] apt-freecad schlug fehl, weiter mit Manager"
  else
    case "${FREECAD_VERSION}" in
      1.0.1) AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.0.1/FreeCAD_1.0.1-conda-Linux-x86_64-py311.AppImage";;
      1.1.2) AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.1.2/FreeCAD_1.1.2-conda-Linux-x86_64-py311.AppImage";;
      1.1.3) AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.1.3/FreeCAD_1.1.3-conda-Linux-x86_64-py311.AppImage";;
      weekly) AI_URL="https://github.com/FreeCAD/FreeCAD-Bundle/releases/download/weekly-builds/FreeCAD_Linux-x86_64-py311.AppImage";;
      *) echo "[payload] Unbekannte Version ${FREECAD_VERSION}, nutze 1.1.3"
         AI_URL="https://github.com/FreeCAD/FreeCAD/releases/download/1.1.3/FreeCAD_1.1.3-conda-Linux-x86_64-py311.AppImage";;
    esac
    if [[ ! -s /opt/freecad/FreeCAD.AppImage ]]; then
      wget -O /opt/freecad/FreeCAD.AppImage -c "$AI_URL"
    else
      echo "[payload] AppImage existiert bereits, überspringe Download (idempotent)"
    fi
    chmod +x /opt/freecad/FreeCAD.AppImage
    # Headless-Alias für Manager (freecadcmd aus AppImage extrahieren scheitert oft ohne FUSE -> Fallback apt freecadcmd)
    apt-get install -y freecadcmd 2>/dev/null || apt-get install -y freecad 2>/dev/null || true
  fi

  # KasmVNC für Browser-Desktop (:6080) — best effort, Manager läuft auch ohne
  if ! command -v kasmvncserver >/dev/null 2>&1; then
    echo "[payload] Installiere KasmVNC (best effort)…"
    (wget -O /tmp/kasmvnc.deb "https://github.com/kasmtech/KasmVNC/releases/download/v1.3.3/kasmvncserver_bookworm_1.3.3_amd64.deb" \
      && apt-get install -y /tmp/kasmvnc.deb) || echo "[payload] KasmVNC-Install übersprungen (weiter ohne Desktop-Streaming)"
  fi

  # Manager-App + venv von GitHub (Fallback: bereits vorhandene main.py behalten = idempotent)
  if [[ ! -s /opt/freecad-manager/main.py ]] || [[ "${FORCE_REFETCH:-0}" == "1" ]]; then
    wget -O /opt/freecad-manager/main.py "${GITHUB_BASE}/app/main.py" || echo "[payload] GitHub-Fetch fehlgeschlagen, nutze vorhandene main.py"
  fi
  wget -O /opt/freecad-manager/requirements.txt "${GITHUB_BASE}/app/requirements.txt" || true
  if [[ ! -x /opt/freecad-manager/venv/bin/python ]]; then
    python3 -m venv /opt/freecad-manager/venv
  fi
  /opt/freecad-manager/venv/bin/pip install -q -r /opt/freecad-manager/requirements.txt || \
    /opt/freecad-manager/venv/bin/pip install -q fastapi 'uvicorn[standard]' python-multipart

  wget -O /etc/systemd/system/freecad.service "${GITHUB_BASE}/systemd/freecad.service" || echo "[payload] service-fetch fehlgeschlagen"
  wget -O /etc/systemd/system/freecad-desktop.service "${GITHUB_BASE}/systemd/freecad-desktop.service" || echo "[payload] desktop-service-fetch fehlgeschlagen"
  systemctl daemon-reload
  systemctl enable freecad.service freecad-desktop.service || true
  systemctl restart freecad.service
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
  echo "Fertig! Manager: http://${IP}:${APP_PORT}  |  Desktop (KasmVNC): http://${IP}:${DESKTOP_PORT}"
}

if [[ "$PAYLOAD_ONLY" == "1" ]]; then
  payload_install
  exit 0
fi

# ================= Host-Seite (Proxmox) =================
[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct >/dev/null 2>&1 || command -v qm >/dev/null 2>&1 || die " Weder pct noch qm gefunden — auf dem Proxmox-Host ausführen."
command -v wget >/dev/null 2>&1 || { apt-get update && apt-get install -y wget curl; }

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
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$(basename $TEMPLATE .tar.zst | head -c 20)"; then
    log "Lade Template $TEMPLATE…"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || die "Template-Download fehlgeschlagen"
  fi
  # ------ Belegte CTID -> automatisch nächste freie nehmen (kein Abbruch, kein Überschreiben) -----
  if pct status "$CTID" >/dev/null 2>&1; then
    warn "CT $CTID ist belegt – nehme automatisch die nächste freie ID."
    while pct status "$CTID" >/dev/null 2>&1; do CTID=$((CTID+1)); done
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
  CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  log "Installiere Payload in CT $CTID…"
  # Payload idempotent via pct push/exec (fällt auf curl im Gast zurück)
  pct push "$CTID" /dev/null /tmp/probe 2>/dev/null || true
  pct exec "$CTID" -- bash -c "FREECAD_VERSION=$FREECAD_VERSION APP_PORT=$APP_PORT DESKTOP_PORT=$DESKTOP_PORT GITHUB_BASE=$GITHUB_BASE bash -c \"\$(wget -qLO - $GITHUB_BASE/install/freecad.sh)\" -- --payload-only --freecad-version $FREECAD_VERSION"
  pct exec "$CTID" -- systemctl is-active freecad.service
  pct exec "$CTID" -- curl -fsS "http://localhost:${APP_PORT}/healthz"
  CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
  ok "Service läuft, Web UI antwortet."
  echo "Fertig! Web UI: http://${CT_IP}:${APP_PORT}  (Desktop in LXC nur Headless — für GUI VM-Modus nehmen)"
  exit 0
fi

# ---------- VM-Pfad (empfohlen für FreeCAD) ----------
# ------ Belegte VMID -> automatisch nächste freie nehmen (kein Abbruch, kein Überschreiben) -----
if qm status "$VMID" >/dev/null 2>&1; then
  warn "VM $VMID ist belegt – nehme automatisch die nächste freie ID."
  while qm status "$VMID" >/dev/null 2>&1; do VMID=$((VMID+1)); done
  log "Neue VMID: $VMID"
fi
log "Lege VM $VMID an (KVM, FreeCAD-GUI + GPU)…"
qm create "$VMID" --name "$HOSTNAME" --cores "$CPU" --memory "$RAM" \
  --net0 virtio,bridge="$BRIDGE" --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}:${DISK}" --ide2 "${STORAGE}:cloudinit" \
  --boot c --bootdisk scsi0 --serial0 socket --vga serial0 \
  --agent enabled=1 --onboot 1 --ostype l26
ok "VM $VMID erstellt."

# GPU-Auto-Versuch (wenn nicht automatisch geht -> README §4, manueller vGPU-Weg)
case "$GPU_MODE" in
  virtio-gl)
    qm set "$VMID" --vga virtio-gl || warn "virtio-gl konnte nicht gesetzt werden (Host ohne VirGL — weiter mit Standard-VGA, KasmVNC nutzt llvmpipe)"
    ok "GPU-Modus virtio-gl gesetzt (3D ohne Passthrough; reicht für FreeCAD-Browser-Desktop)."
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

qm start "$VMID" || true
ok "VM $VMID gestartet (onboot: 1)."

echo ""
echo "================ NÄCHSTER SCHRITT (in der VM) ================"
echo "Die VM braucht noch die Gast-Installation (Debian 12 + FreeCAD + Web UI)."
echo "Führe IN DER VM (Konsole/SSH, als root) aus:"
echo ""
echo "  bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/freecad.sh)\" -- --payload-only --freecad-version ${FREECAD_VERSION}"
echo ""
echo "Danach: Manager http://<VM-IP>:${APP_PORT}  |  Desktop http://<VM-IP>:${DESKTOP_PORT}"
echo "VM-IP ermitteln: qm guest cmd $VMID network-get-interfaces  (Guest-Agent)  oder  qm config $VMID"
echo "vGPU geht nicht automatisch? -> README §4 (manueller Weg: vGPU-Manager, mdev, hostpci, GRID-Guest-Treiber)."
echo "=============================================================="

# Falls Guest-Agent schon antwortet, Payload automatisch versuchen (best effort)
if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
  log "Guest-Agent antwortet — versuche automatische Payload-Installation…"
  qm guest exec "$VMID" -- bash -c "wget -qLO /tmp/fc.sh $GITHUB_BASE/install/freecad.sh && bash /tmp/fc.sh --payload-only --freecad-version $FREECAD_VERSION" || \
    warn "Auto-Payload via Guest-Agent fehlgeschlagen — bitte manuell in der VM ausführen (Befehl oben)."
else
  warn "Guest-Agent antwortet noch nicht — bitte Payload manuell in der VM ausführen (Befehl oben)."
fi
