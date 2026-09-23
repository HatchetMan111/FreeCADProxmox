# 🛠️ FreeCAD Proxmox Manager

Lokale FreeCAD-Anwendung auf Proxmox VE im Stil der **Proxmox VE Community Scripts**
(`community-scripts.github.io/ProxmoxVE`): **Einzeiler → KVM-VM (empfohlen, GUI+GPU) oder LXC (nur Manager+Headless) → Web-UI auf Port 8080 + Desktop im Browser auf 6080.**

- **App:** Python/FastAPI, läuft vollständig lokal, keine Cloud
- **Web-UI (Manager):** `http://<IP>:8080` — Dashboard, FreeCAD-Install (Version wählbar), Datei-Upload/Headless-Info, **VM-/LXC-Installer mit Weboberfläche** (Modus, ID, CPU/RAM/Disk/Storage/Bridge/GPU — alles einstellbar), GPU/vGPU-Status, Logs
- **Desktop nutzen:** `https://<IP>:6080` (HTTPS mit selbstsigniertem Zertifikat — im Browser einmal akzeptieren!) — XFCE + FreeCAD im Browser (KasmVNC), dort konstruieren wie lokal
  (Login-frei via `-disableBasicAuth` + `-SecurityTypes None` — nur für vertrauenswürdiges LAN gedacht!).
- **FreeCAD-Quelle:** https://github.com/FreeCAD/FreeCAD/releases (Stable **1.1.3**, auch 1.0.1/1.1.2/weekly; Linux-AppImage)
- **Standard-Addon:** [Robust MCP Suite](https://spkane.github.io/freecad-addon-robust-mcp-server/latest/) (150+ KI-Tools via MCP) — Workbench `~/.FreeCAD/Mod/freecad-addon-robust-mcp-server` + PyPI-Paket `freecad-robust-mcp`. Nutzung: FreeCAD → Workbench **Robust MCP Bridge** → **Start Bridge** (XML-RPC `:9875`), MCP-Client (Claude/Cursor) darauf zeigen. Status im Manager-Dashboard (`freecad.mcp_workbench` / `freecad.mcp_server`).
- **Headless-MCP (empfohlen, kein Desktop nötig):** `freecad-mcp.service` startet `FreeCADCmd blocking_bridge.py` automatisch → `:9875` (XML-RPC) + `:9876` (Socket). Prüfen: `systemctl is-active freecad-mcp.service`, `ss -tlnp | grep -E '9875|9876`'. Manager-Dashboard zeigt den Service unter `services.mcp`.
- **Repo-Layout (GitHub-first):** `app/` · `install/freecad.sh` · `systemd/` · `README.md`

> ✅ Repo: `HatchetMan111/FreeCADProxmox` (Variablen oben in `install/freecad.sh`: `GITHUB_USER`, `GITHUB_REPO`, `GITHUB_BRANCH`).

## 1. Einzeiler (auf dem Proxmox-HOST als root)

**Standard — VM (empfohlen, 4 CPU / 8 GB / 30 GB, virtio-gl):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)"
```

**Angepasst (VM):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --vmid 200 --cpu 4 --ram 8192 --disk 30 --gpu virtio-gl --freecad-version 1.1.3
```

**Leichtgewichtig als LXC (nur Manager + `freecadcmd`-Headless, kein GPU-Desktop):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --lxc --ctid 150 --cpu 2 --ram 2048 --disk 8
```

**Nur Fallback manuell in der VM (normal läuft die Gast-Installation automatisch via Guest-Agent):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --payload-only --freecad-version 1.1.3
```
> ⚠️ `--payload-only` läuft **in der VM / im LXC (Gast)**, nie auf dem Proxmox-Host — das Script verweigert den Host aktiv (Exit 2).
> Frisch nach einem Push (CDN-Cache): Einzeiler mit Cache-Buster `.../freecad.sh?cb=$(date +%s)` aufrufen.

**Debug (volle Fehlerkette, `bash -x`):**
```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --debug
```

**Update (erneut laufen lassen — belegt = nächste freie ID):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --vmid 200
```
> Das Script ist bewusst **nicht** idempotent gegenüber bestehenden IDs: Ist die CTID/VMID belegt, nimmt es automatisch die nächste freie (kein Überschreiben, kein Abbruch).

**Deinstall:**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --uninstall --vmid 200
# LXC: ... -- --uninstall --lxc --ctid 150
```

## 2. Was der Installer tut

1. Prüft root + `qm`/`pct`, parst Args, `set -euo pipefail` + `trap ERR` mit **kompletter Fehlerkette** (Exit-Code, Zeile, Kommando, Stack, `pveversion`, VM/CT-Status).
2. **VM (Default):** `qm create … --onboot 1` **ohne leere Disk**, dann vollautomatisch: Debian-Cloud-Image laden (`/var/lib/vz/template/iso/`, idempotent) → `qm importdisk` → `qm resize` auf `${DISK}G` → Cloud-Init (`--ciuser/--cipassword/--ipconfig0 dhcp`) → GPU-Auto-Versuch (`virtio-gl` inkl. Host-Libs `libgl1`/`libegl1`, fixt `missing libraries for 'virtio-gl'`) → `qm start` → warten auf Guest-Agent → Payload **automatisch** im Hintergrund (`/var/log/fc-payload.log` in der VM) → Gast-IP via Agent ermitteln → `curl`-Poll auf `:8080/healthz` bis OK.
   Fallback ohne Netz für Cloud-Image: vorhandene Debian-ISO als CDROM (`--iso`, `--boot order=ide0`), dann manuell installieren.
   Eigene FreeCAD-VMs (Name `freecad`) werden bei erneutem Lauf **wiederverwendet** statt neu gebaut; ein Cloud-Init-Snippet installiert `qemu-guest-agent` im Gast automatisch (der Agent-Kanal ist Pflicht für Auto-Payload + IP-Erkennung).
   **LXC:** Debian-Template via `pveam` (idempotent), `pct create … --onboot 1`, optional `/dev/dri`-Passthrough, `pct start`, Payload via `pct exec` direkt.
3. **Payload (Gast, idempotent):** Python3+venv, `app/requirements.txt` (FastAPI/uvicorn), `app/main.py` + `systemd/freecad.service` + `freecad-desktop.service` von GitHub, FreeCAD (apt oder AppImage der gewählten Release-Version von `github.com/FreeCAD/FreeCAD/releases`), XFCE + KasmVNC (best effort), `systemctl enable --now`.
4. Öffnet Ports 8080/6080 (bind `0.0.0.0`), **verifiziert**: `systemctl is-active` + `curl localhost:8080/healthz` (6 Versuche, bei Fehler volles `journalctl` + `ss -tlnp`), druckt finale URLs + Gast-IP.

Erwartete Ausgabe (VM, neu):
```
[freecad] Modus: vm (CPU=4 RAM=8192MB Disk=30GB GPU=virtio-gl FreeCAD=1.1.3)
[OK] VM 201 erstellt (Hülle).          # 200 belegt -> nächste freie, kein Abbruch
[OK] OS-Disk bereit: scsi0=vm-201-disk-1 (30G), Cloud-Init: user=root / dhcp.
[OK] GPU-Modus virtio-gl gesetzt (...)
[OK] VM 201 gestartet (onboot: 1).
[OK] Guest-Agent antwortet.
[OK] Web UI antwortet.
Fertig! Manager: http://192.168.1.61:8080  |  Desktop (KasmVNC, https): https://192.168.1.61:6080
```

> **Alte kaputte VM 200 (leere Disk, kein OS) aufräumen:** `qm stop 200; qm destroy 200` — danach Einzeiler erneut laufen lassen (nimmt automatisch die nächste freie ID). Die `WARNING: thin pools…`-Meldungen sind harmlos (Overprovisioning-Hinweis von LVM). VM-Login per Konsole: `root` / `freecad` (Cloud-Init, `--ciuser`/`--cipass`, nach Install ändern).

Erwartete Ausgabe (Payload in VM/LXC):
```
[OK] Service läuft, Web UI antwortet.
Fertig! Manager: http://192.168.1.60:8080  |  Desktop (KasmVNC, https): https://192.168.1.60:6080
```

## 3. Web-UI — alles einstellen & nutzen

| Tab | Funktion |
|---|---|
| Dashboard | System/FreeCAD/Service, Version wählen + installieren, Desktop starten/stoppen, Link `:6080` |
| FreeCAD & Dateien | `.FCStd/.step/.stl` hochladen → Headless-Info via `freecadcmd`; Konstruieren im Desktop `:6080` |
| **VM / LXC Installer** | Formular: Modus, CTID/VMID, CPU, RAM, Disk, Storage, Bridge, ISO/Template, GPU → generiert `pct`/`qm`-Befehle, optional **direkt ausführen** (nur auf Host) |
| GPU / vGPU | `lspci`, `nvidia-smi`, `/dev/dri`, mdev-Check, `glxinfo` + Anleitung |
| Logs | `app.log` + `journalctl` vollständig (nie nur letzte Zeile) |

Bind: `0.0.0.0:8080` (`APP_PORT`/`BASE_DIR` via Env), systemd `Restart=always`, `After=network-online.target`, CT/VM `onboot: 1` → **reboot-sicher**.

## 4. GPU / vGPU — automatischer vs. manueller Weg

**Automatisch (Script/Web-UI):**
- VM + `--gpu virtio-gl`: `qm set VMID --vga virtio-gl` — 3D ohne Passthrough, reicht für FreeCAD im Browser (llvmpipe/virgl). Geht fast immer.
- LXC + `--gpu passthrough`: reicht `/dev/dri/card0` + `renderD128` durch (`pct set … --dev0/--dev1`). Nur wenn Host `/dev/dri` hat (Intel iGPU / AMD APU).
- VM + `--gpu passthrough/vgpu`: Script legt VM an, prüft `lspci`/`mdev_supported_types`, druckt `qm set`-Vorlage.

**Wenn es NICHT automatisch geht (vGPU/PCIe-Passthrough) — manueller Weg (README-Pfad):**
1. **IOMMU aktivieren (Host, einmalig, Reboot nötig):**
   ```bash
   # Intel: intel_iommu=on iommu=pt | AMD: amd_iommu=on iommu=pt  in /etc/default/grub -> GRUB_CMDLINE_LINUX_DEFAULT
   update-grub && reboot
   dmesg | grep -e IOMMU -e DMAR
   ```
2. **Host-Treiber:** NVIDIA Host-Treiber + **vGPU Manager** installieren (Version muss zu Proxmox-Kernel passen).
   Doku: https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE
3. **Prüfen:**
   ```bash
   lspci -nn | grep -i nvidia
   ls /sys/bus/pci/devices/*/mdev_supported_types
   dmesg | grep -i nvidia
   ```
4. **mdev-Typ wählen und an VM hängen** (z. B. `nvidia-11`, PCI-Adresse anpassen):
   ```bash
   qm set 200 --hostpci0 0000:01:00.0,mdev=nvidia-11
   # echtes PCIe-Passthrough ohne vGPU: qm set 200 --hostpci0 0000:01:00.0,pcie=1
   ```
5. **VM starten, Guest-Treiber (GRID)** in der VM installieren, dann in FreeCAD VBO/antialiasing testen; im Manager unter GPU-Tab `nvidia-smi`/`glxinfo` prüfen.
6. **LXC kann kein echtes vGPU** — für vGPU immer **VM-Modus** nehmen.

Hintergrund:
- https://github.com/FreeCAD/FreeCAD/releases (offizielle Builds; AppImage = stabilste Linux-Methode neben `apt install freecad`)
- https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE
- https://github.com/kasmtech/KasmVNC (Browser-Desktop)

## 5. Testdurchlauf (Installation → Reboot → UI erreichbar)

```bash
# 1) Syntax + App-Check
bash -n install/freecad.sh && echo SYNTAX-OK
python3 -m py_compile app/main.py && echo PY-OK
systemd-analyze verify systemd/freecad.service || true

# 2) App lokal testen (ohne Proxmox)
python3 -m venv /tmp/fc-test && /tmp/fc-test/bin/pip install -q -r app/requirements.txt
BASE_DIR=/tmp/fc-test-data APP_PORT=8080 /tmp/fc-test/bin/python app/main.py &
sleep 6
curl -fsS http://localhost:8080/healthz
curl -fsS http://localhost:8080/api/status | head -c 800

# 3) Auf Proxmox-Host: installieren, rebooten, prüfen
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeCADProxmox/main/install/freecad.sh)" -- --lxc --ctid 150
pct exec 150 -- systemctl is-active freecad.service
pct reboot 150; sleep 15
pct exec 150 -- systemctl is-active freecad.service
curl -fsS http://<CT-IP>:8080/healthz
# VM: qm reboot 200 / in VM: systemctl is-active freecad.service + curl http://<VM-IP>:8080/healthz
```

## 6. Dateien

```
install/freecad.sh            Proxmox-Installer (Variablen oben, set -euo pipefail, idempotent, VM+LXC, vGPU-Auto+Manual)
app/main.py                   FastAPI-App + Web-UI (0.0.0.0:8080, alles einstellbar + nutzbar)
app/requirements.txt          fastapi + uvicorn + python-multipart
systemd/freecad.service       Manager, Restart=always, After=network-online.target
systemd/freecad-desktop.service  KasmVNC-Desktop :6080, Restart=always
README.md                     diese Datei
```

## 7. Debugging

- Installer gibt bei Fehlern **immer die komplette Kette** aus (Exit-Code, Zeile, Kommando, Caller-Stack, `pveversion`, VM/CT-Status) + `bash -x`-Hinweis.
- App gibt JSON mit `traceback` zurück; zusätzlich `/api/logs` und `pct exec <ID> -- journalctl -u freecad.service -n 100 --no-pager`
  bzw. in der VM `journalctl -u freecad.service -n 100 --no-pager`.
