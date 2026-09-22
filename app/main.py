#!/usr/bin/env python3
"""
FreeCAD Proxmox Manager — lokale Web-UI (0.0.0.0:8080).

- Dashboard: System, GPU, FreeCAD-Version, Service-Status
- FreeCAD installieren/starten/stoppen (apt oder AppImage von github.com/FreeCAD/FreeCAD/releases)
- .FCStd/.step/.stl Upload -> freecadcmd Headless-Info/Convert, Download
- VM-/LXC-Installer: generiert (und optional führt aus) pct/qm-Befehle — alles einstellbar
- GPU/vGPU-Check + manuelle Anleitung (wenn Auto-Passthrough nicht geht)
- Alles lokal, keine Cloud. Volle Tracebacks bei Fehlern.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import traceback
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, File, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

APP_NAME = "freecad"
APP_PORT = int(os.environ.get("APP_PORT", "8080"))
BASE_DIR = Path(os.environ.get("BASE_DIR", "/opt/freecad"))
CONFIG_FILE = BASE_DIR / "config.json"
UPLOAD_DIR = BASE_DIR / "uploads"
JOBS_DIR = BASE_DIR / "jobs"
LOG_FILE = BASE_DIR / "app.log"
APPIMAGE = BASE_DIR / "FreeCAD.AppImage"

BASE_DIR.mkdir(parents=True, exist_ok=True)
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
JOBS_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_CONFIG = {
    "app_port": APP_PORT,
    "freecad_version": "1.1.3",  # system | 1.0.1 | 1.1.2 | 1.1.3 | weekly
    "default_mode": "vm",        # vm (empfohlen, GUI+GPU) | lxc (nur Manager+Headless)
    "default_cpu": 4,
    "default_ram_mb": 8192,
    "default_disk_gb": 30,
    "default_storage": "local-lvm",
    "default_bridge": "vmbr0",
    "gpu_mode": "virtio-gl",     # none | virtio-gl | passthrough | vgpu
    "desktop_port": 6080,        # KasmVNC/noVNC
}

FREECAD_RELEASES = {
    "1.0.1": "https://github.com/FreeCAD/FreeCAD/releases/download/1.0.1/FreeCAD_1.0.1-conda-Linux-x86_64-py311.AppImage",
    "1.1.2": "https://github.com/FreeCAD/FreeCAD/releases/download/1.1.2/FreeCAD_1.1.2-Linux-x86_64-py311.AppImage",
    "1.1.3": "https://github.com/FreeCAD/FreeCAD/releases/download/1.1.3/FreeCAD_1.1.3-Linux-x86_64-py311.AppImage",
    "weekly": "https://github.com/FreeCAD/FreeCAD-Bundle/releases/download/weekly-builds/FreeCAD_Linux-x86_64-py311.AppImage",
}

app = FastAPI(title="FreeCAD Proxmox Manager")


def log(msg: str) -> None:
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{datetime.now().isoformat()} {msg}\n")
    except Exception:
        pass


def run(cmd: list[str], timeout: int = 60) -> dict:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"cmd": " ".join(cmd), "exit": p.returncode,
                "stdout": p.stdout[-8000:], "stderr": p.stderr[-8000:]}
    except FileNotFoundError as e:
        return {"cmd": " ".join(cmd), "exit": 127,
                "stdout": "", "stderr": f"nicht gefunden: {e}\n{traceback.format_exc()}"}
    except Exception:
        return {"cmd": " ".join(cmd), "exit": 1,
                "stdout": "", "stderr": traceback.format_exc()}


def err_response(exc: BaseException, ctx: str = "") -> JSONResponse:
    tb = traceback.format_exc()
    log(f"ERROR {ctx}: {exc}\n{tb}")
    return JSONResponse(status_code=500, content={
        "ok": False, "context": ctx, "error": str(exc),
        "traceback": tb, "hint": "Siehe /api/logs und Logdatei.",
    })


def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            return {**DEFAULT_CONFIG, **json.loads(CONFIG_FILE.read_text())}
        except Exception:
            log(f"config defekt, nutze defaults\n{traceback.format_exc()}")
    return dict(DEFAULT_CONFIG)


def save_config(cfg: dict) -> None:
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))


def sys_info() -> dict:
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                mem[k.strip()] = v.strip()
    except Exception:
        mem = {"error": traceback.format_exc(limit=3)}
    disk = shutil.disk_usage("/")
    return {
        "hostname": platform.node(),
        "os": f"{platform.system()} {platform.release()}",
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "mem_total": mem.get("MemTotal", "n/a"),
        "mem_available": mem.get("MemAvailable", "n/a"),
        "disk_total_gb": round(disk.total / 1e9, 1),
        "disk_free_gb": round(disk.free / 1e9, 1),
        "on_proxmox_host": shutil.which("qm") is not None or shutil.which("pct") is not None,
        "in_lxc": Path("/dev/lxc").exists() or os.environ.get("container") == "lxc",
        "time": datetime.now().isoformat(),
    }


def freecad_info() -> dict:
    out: dict = {"binary": None, "version": None, "appimage": APPIMAGE.exists(),
                 "appimage_size_mb": None, "methods": ["apt freecad", "AppImage von github.com/FreeCAD/FreeCAD/releases"]}
    if APPIMAGE.exists():
        try:
            out["appimage_size_mb"] = round(APPIMAGE.stat().st_size / 1e6, 1)
        except Exception:
            pass
    for cand in ["freecad", "FreeCAD", "freecadcmd", str(APPIMAGE)]:
        p = shutil.which(cand) if "/" not in cand else (cand if Path(cand).exists() else None)
        if p:
            out["binary"] = p
            r = run([p, "--version"], timeout=30)
            out["version"] = (r["stdout"] or r["stderr"])[:500]
            out["version_check"] = r
            break
    return out


def gpu_info() -> dict:
    info: dict = {}
    info["lspci_vga"] = run(["sh", "-c", "lspci -nn 2>&1 | grep -iE 'vga|3d|display|nvidia|amd|intel' || lspci 2>&1 | head -30"])
    info["nvidia_smi"] = run(["nvidia-smi", "-L"], timeout=20)
    info["dev_dri"] = run(["sh", "-c", "ls -la /dev/dri /dev/nvidia* 2>&1"])
    info["mdev_types"] = run(["sh", "-c", "ls /sys/bus/pci/devices/*/mdev_supported_types 2>&1; ls /sys/bus/mdev/devices 2>&1 || true"])
    info["glxinfo"] = run(["sh", "-c", "glxinfo -B 2>&1 | head -25 || echo 'kein glxinfo (apt install mesa-utils)'"])
    info["virtio_gl"] = run(["sh", "-c", "lsmod 2>&1 | grep -i virtio || echo 'kein virtio-Modul sichtbar (in VM normal)'"])
    return info


def service_info() -> dict:
    return {
        "manager": run(["systemctl", "is-active", "freecad.service"], timeout=10),
        "desktop": run(["systemctl", "is-active", "freecad-desktop.service"], timeout=10),
        "novnc": run(["systemctl", "is-active", "kasmvnc.service"], timeout=10),
    }


@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    return "ok\n"


@app.get("/api/status")
def api_status():
    try:
        cfg = load_config()
        return {"ok": True, "app": APP_NAME, "config": cfg, "sys": sys_info(),
                "freecad": freecad_info(), "gpu": gpu_info(), "services": service_info()}
    except Exception as e:
        return err_response(e, "status")


@app.get("/api/config")
def api_config_get():
    try:
        return {"ok": True, "config": load_config(), "releases": FREECAD_RELEASES}
    except Exception as e:
        return err_response(e, "config_get")


@app.post("/api/config")
def api_config_post(body: dict):
    try:
        cfg = load_config()
        for k, v in body.items():
            if k in DEFAULT_CONFIG:
                cfg[k] = v
        save_config(cfg)
        log(f"config gespeichert: {body}")
        return {"ok": True, "config": cfg}
    except Exception as e:
        return err_response(e, "config_post")


@app.post("/api/freecad/install")
def api_freecad_install(body: dict | None = None):
    """Installiert FreeCAD: apt (system) oder AppImage der gewählten Release-Version."""
    try:
        cfg = load_config()
        version = (body or {}).get("version", cfg.get("freecad_version", "1.1.3"))
        cfg["freecad_version"] = version
        save_config(cfg)
        steps: list[dict] = []
        if version == "system":
            steps.append(run(["apt-get", "update"], timeout=300))
            steps.append(run(["apt-get", "install", "-y", "freecad", "freecad-common", "calculix-ccx", "mesa-utils"], timeout=900))
        else:
            url = FREECAD_RELEASES.get(version)
            if not url:
                return JSONResponse(status_code=400, content={"ok": False, "error": f"unbekannte Version {version}", "known": list(FREECAD_RELEASES)})
            steps.append(run(["apt-get", "update"], timeout=300))
            steps.append(run(["apt-get", "install", "-y", "wget", "fuse", "libfuse2", "mesa-utils"], timeout=600))
            dl = run(["wget", "-O", str(APPIMAGE), "-c", url], timeout=1800)
            steps.append(dl)
            if dl["exit"] == 0:
                steps.append(run(["chmod", "+x", str(APPIMAGE)], timeout=30))
        log(f"freecad install {version}: " + json.dumps([s["exit"] for s in steps]))
        return {"ok": all(s["exit"] == 0 for s in steps), "version": version,
                "freecad": freecad_info(), "steps": steps}
    except Exception as e:
        return err_response(e, "freecad_install")


@app.post("/api/freecad/desktop/{action}")
def api_desktop(action: str):
    try:
        if action not in ("start", "stop", "restart", "status"):
            return JSONResponse(status_code=400, content={"ok": False, "error": "action: start|stop|restart|status"})
        if action == "status":
            return {"ok": True, "services": service_info(), "freecad": freecad_info()}
        r1 = run(["systemctl", action, "freecad-desktop.service"], timeout=60)
        r2 = run(["systemctl", action, "kasmvnc.service"], timeout=60)
        cfg = load_config()
        return {"ok": r1["exit"] == 0, "desktop": r1, "novnc": r2,
                "hint": f"Desktop im Browser (https, Zertifikat akzeptieren): https://<IP>:{cfg.get('desktop_port', 6080)}",
                "freecad": freecad_info()}
    except Exception as e:
        return err_response(e, f"desktop_{action}")


@app.get("/api/files")
def api_files():
    try:
        files = []
        for p in sorted(UPLOAD_DIR.iterdir()):
            if p.is_file():
                files.append({"name": p.name, "size": p.stat().st_size, "mtime": datetime.fromtimestamp(p.stat().st_mtime).isoformat()})
        return {"ok": True, "files": files}
    except Exception as e:
        return err_response(e, "files_list")


@app.post("/api/files/upload")
async def api_upload(file: UploadFile = File(...)):
    try:
        dest = UPLOAD_DIR / Path(file.filename).name
        with open(dest, "wb") as f:
            while chunk := await file.read(1024 * 1024):
                f.write(chunk)
        log(f"upload: {dest} ({dest.stat().st_size} B)")
        return {"ok": True, "name": dest.name, "size": dest.stat().st_size}
    except Exception as e:
        return err_response(e, "upload")


@app.post("/api/files/info")
def api_file_info(body: dict):
    """Headless-Info via freecadcmd (Bauteil-Stats), volle stdout/stderr zurück."""
    try:
        name = body.get("name", "")
        src = (UPLOAD_DIR / Path(name).name)
        if not src.exists():
            return JSONResponse(status_code=404, content={"ok": False, "error": f"{name} nicht gefunden"})
        fc = freecad_info()["binary"] or shutil.which("freecadcmd")
        if not fc:
            return JSONResponse(status_code=409, content={"ok": False, "error": "kein FreeCAD gefunden — erst /api/freecad/install aufrufen"})
        macro = JOBS_DIR / f"info_{src.stem}.py"
        macro.write_text(
            "import sys\n"
            f"src = r'''{src}'''\n"
            "import FreeCAD\n"
            "doc = FreeCAD.openDocument(src)\n"
            "objs = doc.Objects\n"
            "print(f'OBJECTS={len(objs)}')\n"
            "for o in objs[:50]:\n"
            "    print(f'- {o.Label} ({o.TypeId})')\n"
        )
        r = run([fc, "-c", f"exec(open(r'''{macro}''').read())"], timeout=120)
        return {"ok": r["exit"] == 0, "file": name, "run": r}
    except Exception as e:
        return err_response(e, "file_info")


@app.get("/api/gpu")
def api_gpu():
    try:
        return {"ok": True, "gpu": gpu_info()}
    except Exception as e:
        return err_response(e, "gpu")


@app.get("/api/logs")
def api_logs():
    try:
        app_log = LOG_FILE.read_text()[-20000:] if LOG_FILE.exists() else "(noch kein app.log)"
        jr = run(["journalctl", "-u", "freecad.service", "-n", "100", "--no-pager"], timeout=20)
        jd = run(["journalctl", "-u", "freecad-desktop.service", "-n", "50", "--no-pager"], timeout=20)
        return {"ok": True, "app_log": app_log, "journal_manager": jr, "journal_desktop": jd}
    except Exception as e:
        return err_response(e, "logs")


@app.post("/api/installer/generate")
def api_installer_generate(body: dict):
    """Generiert pct/qm-Befehle aus Formular — alles einstellbar (Modus, ID, CPU, RAM, Disk, Storage, Bridge, ISO/Template, GPU)."""
    try:
        mode = body.get("mode", "vm")
        cpu = int(body.get("cpu", 4)); ram = int(body.get("ram_mb", 8192)); disk = int(body.get("disk_gb", 30))
        storage = body.get("storage", "local-lvm"); bridge = body.get("bridge", "vmbr0")
        gpu = body.get("gpu_mode", "virtio-gl")
        ctid = body.get("ctid", 150); vmid = body.get("vmid", 200)
        iso = body.get("iso", "local:iso/debian-12-netinst.iso")
        template = body.get("template", "debian-12-standard_12.2-1_amd64.tar.zst")
        if mode == "lxc":
            cmds = [
                f"pct create {ctid} {template} --hostname freecad --cores {cpu} --memory {ram} "
                f"--rootfs {storage}:{disk} --net0 name=eth0,bridge={bridge},ip=dhcp --onboot 1 --unprivileged 1 --features nesting=1",
                f"pct start {ctid}",
            ]
            if gpu == "passthrough":
                cmds.append(f"pct set {ctid} --dev0 /dev/dri/card0 --dev1 /dev/dri/renderD128  # nur wenn Host /dev/dri hat")
        else:
            cmds = [
                f"qm create {vmid} --name freecad --cores {cpu} --memory {ram} --net0 virtio,bridge={bridge} "
                f"--scsihw virtio-scsi-pci --scsi0 {storage}:{disk} --ide2 {storage}:cloudinit --boot c --bootdisk scsi0 "
                f"--serial0 socket --vga serial0 --agent enabled=1 --onboot 1",
                f"qm importdisk {vmid} /var/lib/vz/template/iso/debian-12-generic-amd64.qcow2 {storage}  # Cloud-Image, siehe README",
                f"qm set {vmid} --scsi0 {storage}:vm-{vmid}-disk-1",
            ]
            if gpu == "virtio-gl":
                cmds.append(f"qm set {vmid} --vga virtio-gl  # 3D-Beschleunigung ohne Passthrough (KasmVNC nutzt llvmpipe/virgl)")
            elif gpu in ("passthrough", "vgpu"):
                cmds.append(f"# MANUELL (siehe README §4, wenn Auto nicht geht): qm set {vmid} --hostpci0 0000:01:00.0,mdev=nvidia-11")
            cmds.append(f"qm start {vmid}")
        return {"ok": True, "mode": mode, "commands": cmds}
    except Exception as e:
        return err_response(e, "installer_generate")


@app.post("/api/installer/run")
def api_installer_run(body: dict):
    """Führt Generierung direkt aus — nur wenn UI auf dem Proxmox-Host läuft (qm/pct vorhanden), sonst Befehle kopieren."""
    try:
        if not (shutil.which("qm") or shutil.which("pct")):
            return JSONResponse(status_code=409, content={"ok": False,
                "error": "läuft nicht auf dem Proxmox-Host (kein qm/pct). Befehle aus /api/installer/generate kopieren.",
                "traceback": "installer_run nur auf Host mit qm/pct möglich."})
        gen_cmds = api_installer_generate(body)
        if isinstance(gen_cmds, JSONResponse):
            return gen_cmds
        results = []
        for c in gen_cmds["commands"]:
            if c.startswith("#"):
                results.append({"cmd": c, "exit": 0, "stdout": "(Kommentar/Manuell — übersprungen)", "stderr": ""})
                continue
            results.append(run(c.split(), timeout=300))
        return {"ok": all(r["exit"] == 0 for r in results), "results": results}
    except Exception as e:
        return err_response(e, "installer_run")


PAGE = """<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeCAD Proxmox Manager</title>
<style>
body{font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;margin:0}
header{background:#1e293b;padding:14px 20px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
h1{font-size:18px;margin:0}.badge{background:#22c55e;color:#04120a;padding:2px 8px;border-radius:99px;font-size:12px}
main{padding:18px;max-width:1100px;margin:auto}
.card{background:#1e293b;border-radius:12px;padding:16px;margin-bottom:14px}
button{background:#38bdf8;border:0;border-radius:8px;padding:8px 12px;font-weight:600;cursor:pointer;margin:2px}
button.warn{background:#fbbf24}button.danger{background:#f87171}button.ok{background:#4ade80}
input,select{background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:8px;padding:7px;margin:2px}
pre{background:#020617;padding:10px;border-radius:8px;overflow:auto;max-height:320px;font-size:12px}
.tabs button{background:#334155;color:#fff}.tabs button.active{background:#38bdf8;color:#04121a}
small{color:#94a3b8}a{color:#7dd3fc}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{border-bottom:1px solid #334155;padding:6px;text-align:left}
</style></head><body>
<header><h1>🛠️ FreeCAD Proxmox Manager</h1><span class="badge">lokal · keine Cloud</span>
<span id="fcver"><small>lade…</small></span></header>
<main>
<div class="card tabs">
<button class="active" onclick="tab('dash',this)">Dashboard</button>
<button onclick="tab('cad',this)">FreeCAD &amp; Dateien</button>
<button onclick="tab('inst',this)">VM / LXC Installer</button>
<button onclick="tab('gpu',this)">GPU / vGPU</button>
<button onclick="tab('logs',this)">Logs</button>
</div>

<div class="card" id="t-dash"><h3>Dashboard</h3>
<div><label>FreeCAD-Version <select id="cfg-ver">
<option>system</option><option>1.0.1</option><option>1.1.2</option><option selected>1.1.3</option><option>weekly</option>
</select></label>
<button class="ok" onclick="installFc()">FreeCAD installieren</button>
<button onclick="desktop('start')">Desktop starten</button>
<button class="warn" onclick="desktop('restart')">Desktop restart</button>
<button class="danger" onclick="desktop('stop')">Desktop stoppen</button>
<a id="deskLink" href="#" target="_blank"><button>🖥️ Desktop öffnen (:6080)</button></a></div>
<pre id="status">lade Status…</pre></div>

<div class="card" id="t-cad" style="display:none"><h3>FreeCAD &amp; Dateien</h3>
<p><small>.FCStd / .step / .stl hochladen → Headless-Info via <code>freecadcmd</code>. Echte Konstruktion im <b>Desktop (:6080)</b> via KasmVNC.</small></p>
<input type="file" id="up"><button onclick="upload()">Upload</button>
<button onclick="loadFiles()">Aktualisieren</button>
<pre id="files"></pre>
<div><input id="fname" placeholder="datei.FCStd"><button onclick="finfo()">Headless-Info</button></div>
<pre id="finfo"></pre></div>

<div class="card" id="t-inst" style="display:none"><h3>VM / LXC Installer — alles einstellbar</h3>
<p><small>Generiert <code>pct</code>/<code>qm</code>-Befehle. Direkt-Ausführen nur wenn diese UI auf dem Proxmox-Host läuft, sonst kopieren.</small></p>
<label>Modus <select id="i-mode"><option value="vm" selected>VM (empfohlen: GUI+GPU)</option><option value="lxc">LXC (nur Manager+Headless)</option></select></label>
<label>CTID <input id="i-ctid" value="150" size="5"></label>
<label>VMID <input id="i-vmid" value="200" size="5"></label><br>
<label>CPU <input id="i-cpu" value="4" size="4"></label>
<label>RAM MB <input id="i-ram" value="8192" size="7"></label>
<label>Disk GB <input id="i-disk" value="30" size="5"></label><br>
<label>Storage <input id="i-storage" value="local-lvm"></label>
<label>Bridge <input id="i-bridge" value="vmbr0"></label>
<label>GPU <select id="i-gpu"><option value="virtio-gl" selected>virtio-gl (3D ohne Passthrough)</option><option value="none">none</option><option value="passthrough">passthrough (/dev/dri oder PCIe)</option><option value="vgpu">vgpu (NVIDIA vGPU, manuell)</option></select></label><br>
<button class="ok" onclick="genInst()">Befehle generieren</button>
<button class="warn" onclick="runInst()">Direkt ausführen (nur Host)</button>
<pre id="inst"></pre></div>

<div class="card" id="t-gpu" style="display:none"><h3>GPU / vGPU</h3>
<p><small>Auto: <code>virtio-gl</code> (VM) oder <code>/dev/dri</code> (LXC). Wenn vGPU nicht automatisch geht → <b>README §4</b>: NVIDIA vGPU Manager auf Host, mdev-Typ wählen, <code>qm set VMID --hostpci0 …</code>, Guest-GRID-Treiber.</small></p>
<button onclick="loadGpu()">Neu laden</button><pre id="gpu"></pre></div>

<div class="card" id="t-logs" style="display:none"><h3>Logs (komplette Kette, nie nur letzte Zeile)</h3>
<button onclick="loadLogs()">Neu laden</button><pre id="logs"></pre></div>
</main>
<script>
function tab(id,btn){document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));btn.classList.add('active');
['dash','cad','inst','gpu','logs'].forEach(t=>document.getElementById('t-'+t).style.display=(t===id?'block':'none'))}
async function j(u,o){const r=await fetch(u,o);const t=await r.text();try{return JSON.parse(t)}catch(e){return {raw:t,status:r.status}}}
async function refresh(){const s=await j('/api/status');document.getElementById('status').textContent=JSON.stringify(s,null,2).slice(0,12000);
try{document.getElementById('fcver').innerHTML='<small>'+(s.freecad.version||s.freecad.binary||'FreeCAD fehlt')+'</small>'}catch(e){}
const port=(s.config&&s.config.desktop_port)||6080;document.getElementById('deskLink').href='https://'+location.hostname+':'+port;}
async function installFc(){const v=document.getElementById('cfg-ver').value;
document.getElementById('status').textContent='installiere '+v+' … (kann Minuten dauern, AppImage ~800MB)';
const r=await j('/api/freecad/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({version:v})});
document.getElementById('status').textContent=JSON.stringify(r,null,2).slice(0,15000);refresh()}
async function desktop(a){const r=await j('/api/freecad/desktop/'+a,{method:'POST'});alert(JSON.stringify(r).slice(0,800));refresh()}
async function upload(){const f=document.getElementById('up').files[0];if(!f)return alert('Datei wählen');const d=new FormData();d.append('file',f);
const r=await fetch('/api/files/upload',{method:'POST',body:d});alert(await r.text());loadFiles()}
async function loadFiles(){const r=await j('/api/files');document.getElementById('files').textContent=JSON.stringify(r,null,2)}
async function finfo(){const n=document.getElementById('fname').value;const r=await j('/api/files/info',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n})});document.getElementById('finfo').textContent=JSON.stringify(r,null,2).slice(0,12000)}
function instBody(){return {mode:document.getElementById('i-mode').value,ctid:parseInt(document.getElementById('i-ctid').value),vmid:parseInt(document.getElementById('i-vmid').value),cpu:parseInt(document.getElementById('i-cpu').value),ram_mb:parseInt(document.getElementById('i-ram').value),disk_gb:parseInt(document.getElementById('i-disk').value),storage:document.getElementById('i-storage').value,bridge:document.getElementById('i-bridge').value,gpu_mode:document.getElementById('i-gpu').value}}
async function genInst(){const r=await j('/api/installer/generate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(instBody())});document.getElementById('inst').textContent=JSON.stringify(r,null,2)}
async function runInst(){const r=await j('/api/installer/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(instBody())});document.getElementById('inst').textContent=JSON.stringify(r,null,2).slice(0,15000)}
async function loadGpu(){const r=await j('/api/gpu');document.getElementById('gpu').textContent=JSON.stringify(r,null,2).slice(0,15000)}
async function loadLogs(){const r=await j('/api/logs');document.getElementById('logs').textContent=(r.app_log||'').slice(-6000)+'\\n\\n--- journal manager ---\\n'+JSON.stringify(r.journal_manager,null,2).slice(0,6000)}
refresh();loadFiles();
</script></body></html>
"""


@app.get("/", response_class=HTMLResponse)
def index():
    return PAGE


if __name__ == "__main__":
    import uvicorn
    log(f"start {APP_NAME} port={APP_PORT} base={BASE_DIR} py={sys.version.split()[0]}")
    uvicorn.run(app, host="0.0.0.0", port=APP_PORT)
