import base64
import hashlib
import hmac
import html
import json
import os
import secrets
import smtplib
import subprocess
import time
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path
from typing import Dict, List, Optional

from fastapi import FastAPI, Form, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, PlainTextResponse


APP_TITLE = "ChinaVPN 管理面板"
VPN_CIDR = os.getenv("VPN_CIDR", "10.66.0.0/24")
SERVER_VPN_IP = os.getenv("SERVER_VPN_IP", "10.66.0.1")
SERVER_ENDPOINT = os.getenv("SERVER_ENDPOINT", "chinavpn.mikezhuang.cn")
VPN_PORT = os.getenv("VPN_PORT", "41194")
DNS_SERVERS = os.getenv("DNS_SERVERS", "223.5.5.5,119.29.29.29")
MTU = os.getenv("MTU", "1280")
WG_INTERFACE = os.getenv("WG_INTERFACE", "wg0")
WG_CONFIG_PATH = Path(os.getenv("WG_CONFIG_PATH", "/etc/wireguard/wg0.conf"))
DATA_DIR = Path(os.getenv("VPN_PANEL_DATA_DIR", "/opt/chinavpn-panel"))
PEERS_PATH = DATA_DIR / "peers.json"
CLIENT_CONFIG_DIR = DATA_DIR / "client-configs"
QR_DIR = DATA_DIR / "qr-codes"
SESSION_TTL_SECONDS = 12 * 60 * 60
OTP_TTL_SECONDS = 10 * 60
OTP_VERIFIED_SECONDS = 10 * 60

app = FastAPI()


def now() -> int:
    return int(time.time())


def runCommand(args: List[str], inputText: Optional[str] = None) -> str:
    result = subprocess.run(
        args,
        input=inputText,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"command failed: {' '.join(args)}")
    return result.stdout.strip()


def getSecret(name: str) -> str:
    value = os.getenv(name, "")
    if not value:
        raise RuntimeError(f"missing env: {name}")
    return value


def signValue(value: str) -> str:
    secret = getSecret("VPN_PANEL_SECRET").encode()
    digest = hmac.new(secret, value.encode(), hashlib.sha256).hexdigest()
    return f"{value}.{digest}"


def verifySignedValue(signedValue: str) -> Optional[str]:
    if "." not in signedValue:
        return None
    value, digest = signedValue.rsplit(".", 1)
    expected = hmac.new(getSecret("VPN_PANEL_SECRET").encode(), value.encode(), hashlib.sha256).hexdigest()
    if hmac.compare_digest(digest, expected):
        return value
    return None


def verifyPassword(password: str) -> bool:
    expectedHash = getSecret("VPN_PANEL_PASSWORD_SHA256")
    actualHash = hashlib.sha256(password.encode()).hexdigest()
    return hmac.compare_digest(actualHash, expectedHash)


def getSession(request: Request) -> Optional[Dict[str, int]]:
    rawCookie = request.cookies.get("vpn_panel_session")
    if not rawCookie:
        return None
    value = verifySignedValue(rawCookie)
    if not value:
        return None
    try:
        session = json.loads(base64.urlsafe_b64decode(value.encode()).decode())
    except Exception:
        return None
    if session.get("expiresAt", 0) < now():
        return None
    return session


def requireSession(request: Request) -> Dict[str, int]:
    session = getSession(request)
    if not session:
        raise HTTPException(status_code=303, headers={"Location": "/login"})
    return session


def setSessionCookie(response: Response, session: Dict[str, int]) -> None:
    encoded = base64.urlsafe_b64encode(json.dumps(session, separators=(",", ":")).encode()).decode()
    response.set_cookie(
        "vpn_panel_session",
        signValue(encoded),
        httponly=True,
        secure=False,
        samesite="lax",
        max_age=SESSION_TTL_SECONDS,
    )


def escape(value: object) -> str:
    return html.escape(str(value), quote=True)


def renderPage(title: str, body: str, session: Optional[Dict[str, int]] = None) -> HTMLResponse:
    nav = ""
    if session:
        nav = '<nav><a href="/">仪表盘</a><a href="/otp">邮箱校验</a><form method="post" action="/logout"><button>退出</button></form></nav>'
    return HTMLResponse(
        f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{escape(title)}</title>
  <style>
    :root {{ --bg:#f5f6f2; --surface:#fff; --text:#17201b; --muted:#637067; --line:#dce1db; --accent:#146c5f; --danger:#a7392d; --warn:#9b5b15; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }}
    main {{ width:min(1180px, calc(100% - 28px)); margin:0 auto; padding:24px 0 48px; }}
    header {{ display:flex; align-items:center; justify-content:space-between; gap:16px; padding:18px 0; }}
    h1 {{ margin:0; font-size:30px; letter-spacing:0; }}
    h2 {{ margin:0 0 14px; font-size:18px; }}
    p {{ color:var(--muted); line-height:1.7; }}
    nav {{ display:flex; align-items:center; gap:10px; flex-wrap:wrap; }}
    nav a, button, .button {{ border:1px solid var(--line); background:var(--surface); color:var(--text); border-radius:8px; padding:9px 13px; text-decoration:none; cursor:pointer; font-weight:700; }}
    button.primary, .button.primary {{ background:var(--accent); color:#fff; border-color:var(--accent); }}
    button.danger {{ background:var(--danger); color:#fff; border-color:var(--danger); }}
    .grid {{ display:grid; grid-template-columns:repeat(4, minmax(0,1fr)); gap:12px; }}
    .card {{ background:var(--surface); border:1px solid var(--line); border-radius:8px; padding:16px; }}
    .metric {{ font-size:28px; font-weight:850; margin-top:8px; }}
    .muted {{ color:var(--muted); }}
    .warn {{ color:var(--warn); font-weight:800; }}
    table {{ width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--line); border-radius:8px; overflow:hidden; }}
    th,td {{ padding:12px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; }}
    th {{ color:var(--muted); font-size:13px; background:#fafbf8; }}
    input, select {{ width:100%; border:1px solid var(--line); border-radius:8px; padding:10px 12px; font:inherit; background:#fff; }}
    label {{ display:block; color:var(--muted); font-size:13px; margin-bottom:6px; }}
    form.inline {{ display:inline; }}
    .formGrid {{ display:grid; grid-template-columns:repeat(3, minmax(0,1fr)); gap:12px; align-items:end; }}
    .message {{ border-left:4px solid var(--accent); background:#eef7f4; padding:12px 14px; margin:12px 0; }}
    .actions {{ display:flex; gap:8px; flex-wrap:wrap; }}
    @media (max-width:860px) {{ .grid,.formGrid {{ grid-template-columns:1fr; }} table {{ display:block; overflow-x:auto; }} header {{ align-items:flex-start; flex-direction:column; }} }}
  </style>
</head>
<body>
  <main>
    <header><h1>{escape(title)}</h1>{nav}</header>
    {body}
  </main>
</body>
</html>"""
    )


def loadPeers() -> Dict[str, Dict[str, object]]:
    if not PEERS_PATH.exists():
        return {}
    return json.loads(PEERS_PATH.read_text())


def savePeers(peers: Dict[str, Dict[str, object]]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tempPath = PEERS_PATH.with_suffix(".tmp")
    tempPath.write_text(json.dumps(peers, ensure_ascii=False, indent=2))
    tempPath.replace(PEERS_PATH)
    os.chmod(PEERS_PATH, 0o600)


def getWgDump() -> Dict[str, Dict[str, str]]:
    output = runCommand(["wg", "show", WG_INTERFACE, "dump"])
    rows = output.splitlines()
    peers: Dict[str, Dict[str, str]] = {}
    for row in rows[1:]:
        columns = row.split("\t")
        if len(columns) < 8:
            continue
        publicKey, presharedKey, endpoint, allowedIps, latestHandshake, rxBytes, txBytes, keepalive = columns[:8]
        peers[publicKey] = {
            "publicKey": publicKey,
            "endpoint": endpoint,
            "allowedIps": allowedIps,
            "latestHandshake": latestHandshake,
            "rxBytes": rxBytes,
            "txBytes": txBytes,
            "keepalive": keepalive,
        }
    return peers


def getServerStatus() -> Dict[str, str]:
    active = runCommand(["systemctl", "is-active", "wg-quick@wg0"])
    enabled = runCommand(["systemctl", "is-enabled", "wg-quick@wg0"])
    forwarding = runCommand(["sysctl", "-n", "net.ipv4.ip_forward"])
    return {"active": active, "enabled": enabled, "forwarding": forwarding}


def formatBytes(value: object) -> str:
    size = float(value or 0)
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if size < 1024:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} PiB"


def formatHandshake(value: object) -> str:
    timestamp = int(value or 0)
    if timestamp <= 0:
        return "从未连接"
    seconds = max(0, now() - timestamp)
    if seconds < 60:
        return f"{seconds}s 前"
    if seconds < 3600:
        return f"{seconds // 60}m 前"
    if seconds < 86400:
        return f"{seconds // 3600}h 前"
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M")


def getNextClientIp(peers: Dict[str, Dict[str, object]], wgPeers: Dict[str, Dict[str, str]]) -> str:
    used = {SERVER_VPN_IP}
    for peer in peers.values():
        if peer.get("clientIp"):
            used.add(str(peer["clientIp"]))
    for peer in wgPeers.values():
        allowedIp = peer.get("allowedIps", "").split(",")[0].replace("/32", "")
        if allowedIp:
            used.add(allowedIp)
    for lastOctet in range(2, 255):
        candidate = f"10.66.0.{lastOctet}"
        if candidate not in used:
            return candidate
    raise RuntimeError("no available client ip")


def normalizeName(name: str) -> str:
    cleaned = "".join(char.lower() if char.isalnum() else "-" for char in name.strip())
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    cleaned = cleaned.strip("-")
    if not cleaned:
        raise RuntimeError("设备名不能为空")
    return cleaned[:40]


def buildClientConfig(clientPrivateKey: str, serverPublicKey: str, clientIp: str, mode: str) -> str:
    allowedIps = "0.0.0.0/0" if mode == "full" else VPN_CIDR
    return f"""[Interface]
PrivateKey = {clientPrivateKey}
Address = {clientIp}/32
DNS = {DNS_SERVERS}
MTU = {MTU}

[Peer]
PublicKey = {serverPublicKey}
Endpoint = {SERVER_ENDPOINT}:{VPN_PORT}
AllowedIPs = {allowedIps}
PersistentKeepalive = 25
"""


def writeConfigAndQr(peerId: str, fullConfig: str, managementConfig: str) -> None:
    CLIENT_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    QR_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CLIENT_CONFIG_DIR, 0o700)
    os.chmod(QR_DIR, 0o700)
    fullPath = CLIENT_CONFIG_DIR / f"{peerId}-full-tunnel.conf"
    managementPath = CLIENT_CONFIG_DIR / f"{peerId}-management-only.conf"
    fullPath.write_text(fullConfig)
    managementPath.write_text(managementConfig)
    os.chmod(fullPath, 0o600)
    os.chmod(managementPath, 0o600)
    runCommand(["qrencode", "-o", str(QR_DIR / f"{peerId}-full-tunnel-qr.png")], fullConfig)
    runCommand(["qrencode", "-o", str(QR_DIR / f"{peerId}-management-only-qr.png")], managementConfig)


def appendPeerToConfig(name: str, publicKey: str, clientIp: str) -> None:
    with WG_CONFIG_PATH.open("a") as configFile:
        configFile.write(f"\n# managed:{name}\n[Peer]\nPublicKey = {publicKey}\nAllowedIPs = {clientIp}/32\n")


def rebuildWireGuard(peers: Dict[str, Dict[str, object]]) -> None:
    wgPeers = getWgDump()
    for publicKey in list(wgPeers.keys()):
        if publicKey in peers:
            continue
        # 非面板管理的历史 peer 不主动移除，避免误伤已有手机/Mac。
    for peer in peers.values():
        publicKey = str(peer["publicKey"])
        if peer.get("disabled"):
            if publicKey in wgPeers:
                runCommand(["wg", "set", WG_INTERFACE, "peer", publicKey, "remove"])
        else:
            runCommand(["wg", "set", WG_INTERFACE, "peer", publicKey, "allowed-ips", f"{peer['clientIp']}/32"])
    applyTrafficLimits(peers)


def applyTrafficLimits(peers: Dict[str, Dict[str, object]]) -> None:
    limitedPeers = [peer for peer in peers.values() if not peer.get("disabled") and int(peer.get("egressMbit") or 0) > 0]
    if not limitedPeers:
        subprocess.run(["tc", "qdisc", "del", "dev", WG_INTERFACE, "root"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    runCommand(["tc", "qdisc", "replace", "dev", WG_INTERFACE, "root", "handle", "1:", "htb", "default", "999"])
    runCommand(["tc", "class", "replace", "dev", WG_INTERFACE, "parent", "1:", "classid", "1:999", "htb", "rate", "1000mbit"])
    for index, peer in enumerate(limitedPeers, start=10):
        rate = f"{int(peer['egressMbit'])}mbit"
        classId = f"1:{index}"
        runCommand(["tc", "class", "replace", "dev", WG_INTERFACE, "parent", "1:", "classid", classId, "htb", "rate", rate, "ceil", rate])
        runCommand(["tc", "filter", "replace", "dev", WG_INTERFACE, "protocol", "ip", "parent", "1:", "prio", str(index), "u32", "match", "ip", "dst", f"{peer['clientIp']}/32", "flowid", classId])


def requireOtpVerified(session: Dict[str, int]) -> None:
    if int(session.get("otpVerifiedUntil", 0)) < now():
        raise HTTPException(status_code=303, headers={"Location": "/otp?need=1"})


def sendOtp(code: str) -> None:
    sender = getSecret("SMTP_USERNAME")
    recipient = os.getenv("OTP_RECIPIENT", sender)
    message = EmailMessage()
    message["Subject"] = "ChinaVPN 管理验证码"
    message["From"] = sender
    message["To"] = recipient
    message.set_content(f"你的 ChinaVPN 管理验证码是：{code}\n\n10 分钟内有效。")
    with smtplib.SMTP_SSL(os.getenv("SMTP_HOST", "smtp.exmail.qq.com"), int(os.getenv("SMTP_PORT", "465")), timeout=15) as smtp:
        smtp.login(sender, getSecret("SMTP_PASSWORD"))
        smtp.send_message(message)


@app.get("/login", response_class=HTMLResponse)
async def loginPage() -> HTMLResponse:
    body = """<section class="card">
  <h2>登录</h2>
  <form method="post" action="/login">
    <label>管理密码</label>
    <input name="password" type="password" autocomplete="current-password" required />
    <p><button class="primary">登录</button></p>
  </form>
</section>"""
    return renderPage("ChinaVPN 登录", body)


@app.post("/login")
async def login(password: str = Form(...)) -> Response:
    if not verifyPassword(password):
        raise HTTPException(status_code=401, detail="密码错误")
    response = Response(status_code=303, headers={"Location": "/"})
    setSessionCookie(response, {"expiresAt": now() + SESSION_TTL_SECONDS, "otpVerifiedUntil": 0})
    return response


@app.post("/logout")
async def logout() -> Response:
    response = Response(status_code=303, headers={"Location": "/login"})
    response.delete_cookie("vpn_panel_session")
    return response


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request) -> HTMLResponse:
    session = requireSession(request)
    status = getServerStatus()
    peers = loadPeers()
    wgPeers = getWgDump()
    totalRx = sum(int(peer.get("rxBytes") or 0) for peer in wgPeers.values())
    totalTx = sum(int(peer.get("txBytes") or 0) for peer in wgPeers.values())
    knownRows = []
    publicToMeta = {str(peer.get("publicKey")): peer for peer in peers.values()}
    for publicKey, wgPeer in wgPeers.items():
        meta = publicToMeta.get(publicKey, {})
        name = meta.get("name", "历史设备")
        disabled = bool(meta.get("disabled"))
        egressMbit = meta.get("egressMbit") or 0
        knownRows.append(
            f"""<tr>
  <td>{escape(name)}<br><span class="muted">{escape(wgPeer.get("allowedIps", ""))}</span></td>
  <td>{formatHandshake(wgPeer.get("latestHandshake"))}<br><span class="muted">{escape(wgPeer.get("endpoint") or "-")}</span></td>
  <td>{formatBytes(wgPeer.get("rxBytes"))} / {formatBytes(wgPeer.get("txBytes"))}</td>
  <td>{'停用' if disabled else '启用'}<br><span class="muted">下行限速 {escape(egressMbit)} Mbit/s</span></td>
  <td><div class="actions">
    {renderPeerActions(publicKey, meta)}
  </div></td>
</tr>"""
        )
    body = f"""<section class="grid">
  <div class="card"><div class="muted">WireGuard</div><div class="metric">{escape(status['active'])}</div></div>
  <div class="card"><div class="muted">开机启动</div><div class="metric">{escape(status['enabled'])}</div></div>
  <div class="card"><div class="muted">IPv4 转发</div><div class="metric">{escape(status['forwarding'])}</div></div>
  <div class="card"><div class="muted">总流量</div><div class="metric">{formatBytes(totalRx)} / {formatBytes(totalTx)}</div></div>
</section>
<section class="card" style="margin-top:12px">
  <h2>新增设备</h2>
  <p class="warn">新增配置、下载配置、二维码、停用设备和限速都需要先完成邮箱验证码。</p>
  <form class="formGrid" method="post" action="/peers/create">
    <div><label>设备名</label><input name="name" placeholder="macbook-air" required /></div>
    <div><label>下行限速 Mbit/s，0 为不限</label><input name="egressMbit" type="number" min="0" max="1000" value="0" /></div>
    <div><button class="primary">生成配置</button></div>
  </form>
</section>
<section style="margin-top:12px">
  <table>
    <thead><tr><th>设备</th><th>最近连接</th><th>接收 / 发送</th><th>状态</th><th>操作</th></tr></thead>
    <tbody>{''.join(knownRows) or '<tr><td colspan="5">暂无 peer</td></tr>'}</tbody>
  </table>
</section>"""
    return renderPage(APP_TITLE, body, session)


def renderPeerActions(publicKey: str, meta: Dict[str, object]) -> str:
    if not meta:
        return '<span class="muted">历史 peer：仅显示统计</span>'
    peerId = escape(meta["id"])
    disabled = bool(meta.get("disabled"))
    toggleLabel = "启用" if disabled else "停用"
    dangerClass = "" if disabled else "danger"
    return f"""
<a class="button" href="/peers/{peerId}/config/full">Full 配置</a>
<a class="button" href="/peers/{peerId}/config/management">管理配置</a>
<a class="button" href="/peers/{peerId}/qr/full">Full QR</a>
<a class="button" href="/peers/{peerId}/qr/management">管理 QR</a>
<form class="inline" method="post" action="/peers/{peerId}/toggle"><button class="{dangerClass}">{toggleLabel}</button></form>
<form class="inline" method="post" action="/peers/{peerId}/limit"><input style="width:86px" name="egressMbit" type="number" min="0" max="1000" value="{escape(meta.get('egressMbit') or 0)}" /><button>限速</button></form>
"""


@app.get("/otp", response_class=HTMLResponse)
async def otpPage(request: Request, need: Optional[str] = None) -> HTMLResponse:
    session = requireSession(request)
    message = '<div class="message">敏感操作需要先完成邮箱验证码。</div>' if need else ""
    verified = int(session.get("otpVerifiedUntil", 0)) >= now()
    state = f'<p class="message">已通过邮箱校验，有效期到 {datetime.fromtimestamp(session["otpVerifiedUntil"]).strftime("%H:%M:%S")}。</p>' if verified else ""
    body = f"""{message}{state}<section class="card">
  <h2>邮箱校验</h2>
  <form method="post" action="/otp/send"><button class="primary">发送验证码到邮箱</button></form>
  <form method="post" action="/otp/verify" style="margin-top:14px">
    <label>验证码</label>
    <input name="code" inputmode="numeric" autocomplete="one-time-code" required />
    <p><button>验证</button></p>
  </form>
</section>"""
    return renderPage("邮箱校验", body, session)


@app.post("/otp/send")
async def otpSend(request: Request) -> Response:
    session = requireSession(request)
    code = f"{secrets.randbelow(1000000):06d}"
    session["otpHash"] = hashlib.sha256(code.encode()).hexdigest()
    session["otpExpiresAt"] = now() + OTP_TTL_SECONDS
    sendOtp(code)
    response = Response(status_code=303, headers={"Location": "/otp"})
    setSessionCookie(response, session)
    return response


@app.post("/otp/verify")
async def otpVerify(request: Request, code: str = Form(...)) -> Response:
    session = requireSession(request)
    if int(session.get("otpExpiresAt", 0)) < now():
        raise HTTPException(status_code=400, detail="验证码已过期")
    actualHash = hashlib.sha256(code.strip().encode()).hexdigest()
    if not hmac.compare_digest(actualHash, str(session.get("otpHash", ""))):
        raise HTTPException(status_code=400, detail="验证码错误")
    session["otpVerifiedUntil"] = now() + OTP_VERIFIED_SECONDS
    response = Response(status_code=303, headers={"Location": "/"})
    setSessionCookie(response, session)
    return response


@app.post("/peers/create")
async def createPeer(request: Request, name: str = Form(...), egressMbit: int = Form(0)) -> Response:
    session = requireSession(request)
    requireOtpVerified(session)
    peers = loadPeers()
    wgPeers = getWgDump()
    peerId = normalizeName(name)
    if peerId in peers:
        peerId = f"{peerId}-{secrets.token_hex(3)}"
    clientIp = getNextClientIp(peers, wgPeers)
    clientPrivateKey = runCommand(["wg", "genkey"])
    clientPublicKey = runCommand(["wg", "pubkey"], clientPrivateKey)
    serverPublicKey = runCommand(["wg", "show", WG_INTERFACE, "public-key"])
    fullConfig = buildClientConfig(clientPrivateKey, serverPublicKey, clientIp, "full")
    managementConfig = buildClientConfig(clientPrivateKey, serverPublicKey, clientIp, "management")
    writeConfigAndQr(peerId, fullConfig, managementConfig)
    appendPeerToConfig(peerId, clientPublicKey, clientIp)
    peers[peerId] = {
        "id": peerId,
        "name": peerId,
        "clientIp": clientIp,
        "publicKey": clientPublicKey,
        "createdAt": now(),
        "disabled": False,
        "egressMbit": max(0, int(egressMbit or 0)),
    }
    savePeers(peers)
    rebuildWireGuard(peers)
    return Response(status_code=303, headers={"Location": "/"})


def getPeerOr404(peerId: str) -> Dict[str, object]:
    peers = loadPeers()
    peer = peers.get(peerId)
    if not peer:
        raise HTTPException(status_code=404, detail="peer not found")
    return peer


@app.post("/peers/{peerId}/toggle")
async def togglePeer(request: Request, peerId: str) -> Response:
    session = requireSession(request)
    requireOtpVerified(session)
    peers = loadPeers()
    peer = peers.get(peerId)
    if not peer:
        raise HTTPException(status_code=404, detail="peer not found")
    peer["disabled"] = not bool(peer.get("disabled"))
    savePeers(peers)
    rebuildWireGuard(peers)
    return Response(status_code=303, headers={"Location": "/"})


@app.post("/peers/{peerId}/limit")
async def limitPeer(request: Request, peerId: str, egressMbit: int = Form(0)) -> Response:
    session = requireSession(request)
    requireOtpVerified(session)
    peers = loadPeers()
    peer = peers.get(peerId)
    if not peer:
        raise HTTPException(status_code=404, detail="peer not found")
    peer["egressMbit"] = max(0, int(egressMbit or 0))
    savePeers(peers)
    rebuildWireGuard(peers)
    return Response(status_code=303, headers={"Location": "/"})


@app.get("/peers/{peerId}/config/{mode}")
async def downloadConfig(request: Request, peerId: str, mode: str) -> PlainTextResponse:
    session = requireSession(request)
    requireOtpVerified(session)
    if mode not in {"full", "management"}:
        raise HTTPException(status_code=404)
    getPeerOr404(peerId)
    suffix = "full-tunnel" if mode == "full" else "management-only"
    path = CLIENT_CONFIG_DIR / f"{peerId}-{suffix}.conf"
    if not path.exists():
        raise HTTPException(status_code=404)
    headers = {"Content-Disposition": f'attachment; filename="{peerId}-{suffix}.conf"'}
    return PlainTextResponse(path.read_text(), headers=headers)


@app.get("/peers/{peerId}/qr/{mode}")
async def downloadQr(request: Request, peerId: str, mode: str) -> Response:
    session = requireSession(request)
    requireOtpVerified(session)
    if mode not in {"full", "management"}:
        raise HTTPException(status_code=404)
    getPeerOr404(peerId)
    suffix = "full-tunnel" if mode == "full" else "management-only"
    path = QR_DIR / f"{peerId}-{suffix}-qr.png"
    if not path.exists():
        raise HTTPException(status_code=404)
    return Response(path.read_bytes(), media_type="image/png")
