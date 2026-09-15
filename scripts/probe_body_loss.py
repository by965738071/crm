#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""框架 body-loss 探针：交替发送「400 中文 text」+「200 JSON」请求对，
用原始 socket 校验每个响应的状态行/Content-Length/body 一致性。
用法: python3 scripts/probe_body_loss.py <admin_cookie> <iters>
前提: 服务器已在 127.0.0.1:8080 运行。"""
import socket, sys, json, re

ADMIN = sys.argv[1] if len(sys.argv) > 1 else ""
ITERS = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
HOST, PORT = "127.0.0.1", 8080

def raw(method, path, cookie, body=None):
    s = socket.create_connection((HOST, PORT), timeout=5)
    head = f"{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nCookie: {cookie}\r\n"
    if body is not None:
        head += f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
    head += "\r\n"
    data = head.encode() + (body if isinstance(body, bytes) else (body.encode() if body is not None else b""))
    s.sendall(data)
    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
        except Exception as e:
            s.close()
            return None, f"recv-error {e}"
        if not chunk:
            break
        buf += chunk
        if len(buf) > 65536:
            break
    s.close()
    return buf, None

def parse(buf):
    # returns (status, cl, header_bytes, body_bytes)
    idx = buf.find(b"\r\n\r\n")
    if idx < 0:
        return None, None, buf, b""
    hdr = buf[:idx]
    body = buf[idx+4:]
    m = re.search(rb"HTTP/1\.[01] (\d{3})", hdr)
    status = int(m.group(1)) if m else None
    m = re.search(rb"Content-Length: (\d+)", hdr, re.I)
    cl = int(m.group(1)) if m else None
    return status, cl, hdr, body

bad = 0
# 400 中文 text：admin 建卷（分值合计不一致）
bad_body = json.dumps({"category_id": 1, "title": "probe bad", "duration_min": 30,
                       "total_score": 99, "pass_score": 10, "status": "published",
                       "rules": [{"type": "single", "category_id": 1, "count": 1, "score_each": 10}]}).encode()
for i in range(ITERS):
    b1, err = raw("POST", "/api/admin/exams", ADMIN, bad_body)
    if err or b1 is None:
        print(f"[{i}] pair1 ERR {err}"); bad += 1; continue
    s1, cl1, _, bd1 = parse(b1)
    if s1 != 400:
        print(f"[{i}] pair1 unexpected status {s1}: {b1[:120]!r}"); bad += 1
    if cl1 is not None and len(bd1) != cl1:
        print(f"[{i}] pair1 CL mismatch cl={cl1} got={len(bd1)}"); bad += 1
    b2, err = raw("GET", "/api/exams", ADMIN, None)
    if err or b2 is None:
        print(f"[{i}] pair2 ERR {err}"); bad += 1; continue
    s2, cl2, h2, bd2 = parse(b2)
    if s2 != 200:
        print(f"[{i}] pair2 unexpected status {s2}: {b2[:120]!r}"); bad += 1
    if cl2 is not None and len(bd2) != cl2:
        print(f"[{i}] pair2 CL MISMATCH cl={cl2} got={len(bd2)} hdr={h2[:200]!r} body={bd2[:80]!r}"); bad += 1
        continue
    try:
        d = json.loads(bd2.decode("utf-8"))
        if not d.get("ok"): print(f"[{i}] pair2 not ok: {bd2[:100]!r}"); bad += 1
    except Exception as e:
        print(f"[{i}] pair2 JSON FAIL {e} hdr={h2[:220]!r} body={bd2[:120]!r}"); bad += 1
    if bad and bad % 50 == 0 and i > 0:
        pass
print(f"DONE iters={ITERS} bad={bad}")
sys.exit(1 if bad else 0)
