#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性导入工具：把《1-内科-习题集-6198题.md》灌进 CRM 系统数据库。

只认这一份 Markdown 的固定版式（# 章 / ## 节 / **【单选题】**…【A】…
【正确答案】…【难易度】…【题目解析】…，##### 分隔题目块）。
下次换别的格式，改这份脚本即可，后端程序不需要任何改动。

用法（在项目根目录、服务已启动时运行）：
    python scripts/import_md.py --dry-run        # 只解析 + 本地预校验
    python scripts/import_md.py                  # 正式导入
    python scripts/import_md.py --password xxx   # admin 密码非默认时

仅依赖 Python 3 标准库。
"""
import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.parse

try:  # Windows GBK 控制台兼容
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 与后端 question_repo 一致的硬限制（单位 = UTF-8 字节数）
MAX_STEM = 4000
MAX_OPTION = 500
MAX_EXPL = 8000
MIN_OPTS = 2
MAX_OPTS = 12

DIFF_MAP = {"易": 1, "中": 3, "难": 5}

QSTART_RE = re.compile(r"^\*\*【(单选题|多选题|判断题)】\*\*(.*)$")
FIELD_RE = re.compile(
    r"^【(A|B|C|D|E|F|G|H|I|J|K|L|M|正确答案|知识点ID|难易度|题目解析|避错)】(.*)$")
# 脏数据兼容：部分配伍题的 F/G/H 选项写成「F：xxx」；心电图题的 A 选项粘在图片行尾
COLON_OPT_RE = re.compile(r"^([A-M])[：.]\s*(\S.*)$")
SEP_RE = re.compile(r"\*+#+\*+")  # 兼容 **#####** 这种加星号的分隔行
IMG_RE = re.compile(
    r"!\[([^\]]*)\]\(\s*data:image/([A-Za-z+]+);base64,([A-Za-z0-9+/=\s]+?)\s*\)", re.S)


def blen(s):
    return len(s.encode("utf-8"))


def clip8(s):
    """后端分类名限 64 UTF-8 字节；超长时按字符边界截断。"""
    b = s.encode("utf-8")
    if len(b) <= 64:
        return s
    return b[:61].decode("utf-8", "ignore") + ".."


def norm_lines(parts):
    """多行字段合并：去空行、每行去首尾空白，行间用 \n 连接。"""
    return "\n".join(t.strip() for t in parts if t and t.strip())


# 图片占位 token：extract 阶段先把 base64 换成 @@IMG:<name>@@，分类确定后再水合成 URL
TOKEN_RE = re.compile(r"@@IMG:([0-9A-Za-z._-]+)@@")
IMG_SLACK = 40  # 预留 token 展开成 ![图](/uploads/…) 的字节增量上限


def extract_images(text, dry_run):
    """base64 内嵌图解码到内存，正文替换成 @@IMG:<name>@@ 占位 token。

    分类在解析阶段才知道，所以拆两段：这里只解码+换 token；
    hydrate_images() 在 category_id 确定后写盘并替换成
    /uploads/images/<cid>/<yyyy-mm>/<name>（与后端 storage.saveImage 惯例一致）。
    """
    stats = {"saved": 0, "reused": 0, "failed": 0}
    blobs = {}  # name -> 原始字节

    def repl(m):
        alt, sub, b64 = m.group(1) or "", m.group(2).lower(), re.sub(r"\s+", "", m.group(3))
        try:
            raw = base64.b64decode(b64)
        except Exception:
            stats["failed"] += 1
            return m.group(0)
        ext = {"png": "png", "jpeg": "jpg", "jpg": "jpg"}.get(sub, sub)
        name = hashlib.sha1(raw).hexdigest()[:16] + "." + ext  # 内容哈希：重复图自动去重
        blobs.setdefault(name, raw)
        # 前后各补一个换行：防止图片 ) 后面粘连的正文（如 A：选项）被同一行吞掉
        return "\n@@IMG:%s@@\n" % name

    return IMG_RE.sub(repl, text), blobs, stats


def clip_tokens(s, limit):
    """按 UTF-8 字节上限截断，且不留下被截成半截的图片链接/token。"""
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s, False
    cut = b[:limit].decode("utf-8", "ignore")
    cut = re.sub(r"(!\[图\]\([^)]*|@@(?:IMG:[0-9A-Za-z._-]*)?@{0,2})$", "", cut)
    return cut, True


def hydrate_images(items, blobs, upload_dir, stats):
    """把 @@IMG:name@@ 水合成 ![图](/uploads/images/<cid>/<yyyy-mm>/<name>) 并落盘。

    必须在 category_id 确定后调用；文件写到 <upload_dir>/<cid>/<yyyy-mm>/。
    水合后复校长度硬限制，超限题剔除（返回 keep, problems）。
    """
    month = time.strftime("%Y-%m")
    keep, problems = [], []
    for it in items:
        body = it["body"]
        cid = str(body["category_id"])
        sub_dir = os.path.join(upload_dir, cid, month)

        def repl(m):
            name = m.group(1)
            raw = blobs.get(name)
            if raw is None:  # 不应发生：token 未命中解码结果，宁可丢图不编造 URL
                return ""
            os.makedirs(sub_dir, exist_ok=True)
            fp = os.path.join(sub_dir, name)
            if os.path.exists(fp):
                stats["reused"] += 1
            else:
                with open(fp, "wb") as f:
                    f.write(raw)
                stats["saved"] += 1
            return "![图](/uploads/images/%s/%s/%s)" % (cid, month, name)

        def sub(s):
            return TOKEN_RE.sub(repl, s)

        body["stem"] = sub(body["stem"])
        body["options"] = [sub(o) for o in body["options"]]
        expl, clipped = clip_tokens(sub(body["explanation"]), MAX_EXPL)
        body["explanation"] = expl
        if clipped:
            stats["expl_clipped"] = stats.get("expl_clipped", 0) + 1

        bad = None
        if blen(body["stem"]) > MAX_STEM:
            bad = "题干水合后 %d 字节 > %d" % (blen(body["stem"]), MAX_STEM)
        else:
            for o in body["options"]:
                if blen(o) > MAX_OPTION:
                    bad = "选项水合后 %d 字节 > %d" % (blen(o), MAX_OPTION)
                    break
        if bad:
            problems.append((it["chapter"], it["section"], body["stem"][:30], bad))
        else:
            keep.append(it)
    return keep, problems


def parse_questions(md_text):
    """按行状态机解析，返回 [(chapter, section, qdict), ...]。

    题挂在 ## 节下；### 只是题型标签头，跳过不建分类；##### 结束一题。
    """
    items = []
    chapter = section = None
    cur = None
    field = None

    def flush():
        nonlocal cur, field
        if cur is not None:
            items.append((chapter, section, cur))
        cur = None
        field = None

    for raw in md_text.splitlines():
        s = raw.strip()
        if s.startswith("###") or SEP_RE.fullmatch(s):  # ###/####/#####：题型头或题目分隔符
            flush()
            continue
        if s.startswith("## "):
            flush()
            section = s[3:].strip()
            continue
        if s.startswith("# "):
            flush()
            chapter = s[2:].strip()
            section = None
            continue

        m = QSTART_RE.match(s)
        if m:
            flush()
            cur = {"qtype": m.group(1), "stem": [m.group(2)],
                   "opts": {}, "answer": "", "diff": "", "expl": []}
            field = "stem"
            continue
        if cur is None:
            continue
        m = FIELD_RE.match(s)
        if m:
            label, rest = m.group(1), m.group(2)
            if len(label) == 1 and label.isalpha():
                field = "opt" + label
                cur["opts"][label] = [rest]
            elif label == "正确答案":
                field = "answer"
                cur["answer"] = rest
            elif label == "难易度":
                field = "diff"
                cur["diff"] = rest
            elif label == "题目解析":
                field = "expl"
                cur["expl"].append(rest)
            elif label == "避错":
                field = "expl"
                cur["expl"].append("【避错】" + rest)
            else:  # 知识点ID：恒空，忽略
                field = "ignore"
            continue
        m = COLON_OPT_RE.match(s)
        if m and ((field == "stem" and m.group(1) == "A")
                  or (field is not None and field.startswith("opt"))):
            field = "opt" + m.group(1)
            cur["opts"][field[3:]] = [m.group(2)]
            continue
        if field == "stem":
            cur["stem"].append(raw)
        elif field == "expl":
            cur["expl"].append(raw)
        elif field and field.startswith("opt"):
            cur["opts"][field[3:]].append(raw)
        # answer / diff / ignore 的续行忽略
    flush()
    return items


def check_one(chapter, section, q):
    """本地镜像后端校验，避免一题坏导致整批入库失败。

    返回 (条目 dict 或 None, 跳过原因或 None, 备注或 None)。
    """
    stem = norm_lines(q["stem"])
    if not stem:
        return None, "题干为空", None
    if blen(stem) + IMG_SLACK * len(TOKEN_RE.findall(stem)) > MAX_STEM:
        return None, "题干 %d 字节(含图片展开余量) > %d" % (blen(stem), MAX_STEM), None

    typ = {"单选题": "single", "多选题": "multi"}.get(q.get("qtype", ""))
    if typ is None:
        return None, "暂不支持题型:%s" % q.get("qtype"), None

    labels = sorted(q["opts"].keys())
    if not (MIN_OPTS <= len(labels) <= MAX_OPTS):
        return None, "选项数 %d（需 2-12）" % len(labels), None
    if labels != [chr(ord("A") + i) for i in range(len(labels))]:
        return None, "选项标号不连续:" + "/".join(labels), None
    opts = []
    for lb in labels:
        text = norm_lines(q["opts"][lb])
        if not text:
            return None, "选项%s为空" % lb, None
        if blen(text) + IMG_SLACK * len(TOKEN_RE.findall(text)) > MAX_OPTION:
            return None, "选项%s %d 字节(含图片展开余量) > %d" % (lb, blen(text), MAX_OPTION), None
        opts.append(text)

    answer = re.sub(r"[\s,，、;；.。]+", "", q["answer"]).upper()
    letters = "".join(sorted(set(answer)))
    if not letters or not re.fullmatch(r"[A-M]+", letters):
        return None, "答案异常:%r" % q["answer"], None
    if any(c not in labels for c in letters):
        return None, "答案越界:%s" % letters, None
    if typ == "single" and len(letters) != 1:
        return None, "单选题答案异常:%s" % letters, None
    if typ == "multi" and len(letters) < 2:
        return None, "多选题答案不足两个:%s" % letters, None

    diff = 3
    for k, v in DIFF_MAP.items():
        if k in q["diff"]:
            diff = v
            break
    expl = norm_lines(q["expl"])
    note = None
    if blen(expl) + IMG_SLACK * len(TOKEN_RE.findall(expl)) > MAX_EXPL:
        # token 空间已逼近上限：URL 比 token 更长，水合后必超，交由 hydrate 阶段截断
        note = "解析 %d 字节(含展开余量)超 %d，水合后截断" % (blen(expl), MAX_EXPL)

    body = {
        "category_id": 0, "course_id": 0, "type": typ,
        "stem": stem, "options": opts, "answer": letters,
        "explanation": expl, "difficulty": diff,
    }
    return {"chapter": chapter, "section": section, "body": body}, None, note


class Api:
    """极简 http.client 封装，手工维持 crm_session cookie。"""

    def __init__(self, base_url):
        u = urllib.parse.urlparse(base_url)
        if u.scheme not in ("http", "https") or not u.hostname:
            raise SystemExit("[错误] --base-url 不正确: " + base_url)
        self.conn_cls = http.client.HTTPSConnection if u.scheme == "https" \
            else http.client.HTTPConnection
        self.host = u.hostname
        self.port = u.port or (443 if u.scheme == "https" else 80)
        self.cookie = None

    def raw(self, method, path, payload=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
        conn = self.conn_cls(self.host, self.port, timeout=180)
        headers = {"Content-Type": "application/json; charset=utf-8"}
        if self.cookie:
            headers["Cookie"] = self.cookie
        try:
            conn.request(method, path, body, headers)
            resp = conn.getresponse()
            status = resp.status
            data = resp.read().decode("utf-8", "replace")
            sc = resp.getheader("Set-Cookie")
            if sc:
                self.cookie = sc.split(";")[0]
        finally:
            conn.close()
        try:
            js = json.loads(data)
        except ValueError:
            js = None
        return status, js, data

    def call(self, method, path, payload=None):
        status, js, data = self.raw(method, path, payload)
        if status in (401, 403):
            raise SystemExit("[错误] HTTP %d：登录状态无效。若 admin 密码已改，用 --password 传正确密码。" % status)
        if status != 200 or not isinstance(js, dict) or not js.get("ok"):
            raise SystemExit("[错误] %s %s -> HTTP %d %s" % (method, path, status, data[:300]))
        return js["data"]


def main():
    ap = argparse.ArgumentParser(
        description="一次性导入工具：《内科习题集》Markdown -> CRM（只适配本格式，改版式请改本脚本）")
    ap.add_argument("--file", default="1-内科-习题集-6198题.md")
    ap.add_argument("--base-url", default="http://127.0.0.1:8080")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="admin123456")
    ap.add_argument("--project-code", default="neike")
    ap.add_argument("--project-name", default="内科学")
    ap.add_argument("--upload-dir", default=os.path.join("data", "uploads", "images"))
    ap.add_argument("--batch-size", type=int, default=450)
    ap.add_argument("--limit", type=int, default=0, help="只导前 N 题（联调用）")
    ap.add_argument("--dry-run", action="store_true", help="只解析+预校验，不落图片不发请求")
    args = ap.parse_args()

    if not os.path.exists(args.file):
        raise SystemExit("[错误] 找不到 MD 文件：%s（在项目根目录运行，或用 --file 指定）" % args.file)
    with open(args.file, "r", encoding="utf-8-sig") as f:
        text = f.read()
    print("已读取 %s（%d 字符）" % (args.file, len(text)))

    text, blobs, imgs = extract_images(text, args.dry_run)
    print("图片提取：唯一图 %d 张（base64 解码失败 %d；落盘延后到水合阶段）" % (len(blobs), imgs["failed"]))

    parsed = parse_questions(text)
    items, skipped, notes = [], [], []
    for i, (ch, sec, q) in enumerate(parsed, 1):
        item, why, note = check_one(ch, sec, q)
        if item is None:
            skipped.append((i, ch, sec, why, q))
        else:
            if note:
                notes.append((ch, sec, note))
            items.append(item)
    print("解析题目 %d；预校验通过 %d；跳过 %d" % (len(parsed), len(items), len(skipped)))
    for i, ch, sec, why, q in skipped[:20]:
        print("  [跳过#%d] %s / %s ｜ %s ｜ %s" % (i, ch, sec, why, norm_lines(q["stem"])[:30]))
    if len(skipped) > 20:
        print("  ...跳过共 %d 条，以上仅前 20 条" % len(skipped))
    for ch, sec, note in notes[:20]:
        print("  [注意] %s / %s ｜ %s" % (ch, sec, note))

    if args.limit and args.limit < len(items):
        items = items[:args.limit]
        print("--limit 生效：只导入前 %d 题" % len(items))
    if args.dry_run:
        print("dry-run 结束（未连服务器、未写任何数据）")
        return
    if not items:
        print("没有可导入的题目，结束")
        return

    api = Api(args.base_url)
    api.call("POST", "/api/auth/login", {"account": args.user, "password": args.password})
    print("登录成功：%s" % args.user)

    projects = api.call("GET", "/api/projects") or []
    project = next((p for p in projects if p.get("code") == args.project_code), None)
    if project is None:
        project = api.call("POST", "/api/admin/projects", {
            "code": args.project_code,
            "name": args.project_name,
            "subject_label": "科目",
            "description": "由 import_md.py 创建（%s）" % os.path.basename(args.file),
            "sort": 0,
        })
        print("已创建专业：%s（id=%s）" % (project["name"], project["id"]))
    else:
        print("复用已有专业：%s（id=%s）" % (project["name"], project["id"]))

    tree = api.call("GET", "/api/categories?project_id=%s" % project["id"]) or []
    root_id = project["root_category_id"]
    ch_id, sec_id = {}, {}
    for node in tree:
        ch_id[clip8(node["name"])] = node["id"]
        for child in node.get("children") or []:
            sec_id[(clip8(node["name"]), clip8(child["name"]))] = child["id"]

    for it in items:
        ch, sec = clip8(it["chapter"]), clip8(it["section"])
        if ch not in ch_id:
            node = api.call("POST", "/api/admin/categories",
                            {"parent_id": root_id, "name": ch, "sort": len(ch_id)})
            ch_id[ch] = node["id"]
        cid = ch_id[ch]
        if sec:
            if (ch, sec) not in sec_id:
                node = api.call("POST", "/api/admin/categories",
                                {"parent_id": cid, "name": sec, "sort": len(sec_id)})
                sec_id[(ch, sec)] = node["id"]
            cid = sec_id[(ch, sec)]
        it["body"]["category_id"] = cid
    print("分类就绪：%d 章 / %d 节（已有的自动复用）" % (len(ch_id), len(sec_id)))

    items, late_bad = hydrate_images(items, blobs, args.upload_dir, imgs)
    print("图片落盘：新写 %d，复用 %d -> %s/<分类id>/<月份>/" % (imgs["saved"], imgs["reused"], os.path.abspath(args.upload_dir)))
    if imgs.get("expl_clipped"):
        print("解析水合后截断至 %d 字节：%d 题" % (MAX_EXPL, imgs["expl_clipped"]))
    if late_bad:
        print("水合后超限剔除 %d 题（不发请求）：" % len(late_bad))
        for ch, sec, hint, why in late_bad[:20]:
            print("  [水合剔除] %s / %s ｜ %s ｜ %s" % (ch, sec, hint, why))

    bs = max(1, min(args.batch_size, 500))
    nb = (len(items) + bs - 1) // bs
    imported = 0
    failed = []
    for bi in range(nb):
        batch = items[bi * bs:(bi + 1) * bs]
        status, js, data = api.raw("POST", "/api/admin/questions/import",
                                   {"questions": [it["body"] for it in batch]})
        if status == 200 and isinstance(js, dict) and js.get("ok"):
            imported += js["data"]["imported"]
            print("[%d/%d] 批次导入 %d 题（累计 %d）" % (bi + 1, nb, js["data"]["imported"], imported))
        else:
            print("[%d/%d] 整批失败 -> %s；改逐题导入定位坏题" % (bi + 1, nb, data[:200]))
            for it in batch:
                s2, j2, d2 = api.raw("POST", "/api/admin/questions/import",
                                     {"questions": [it["body"]]})
                if s2 == 200 and isinstance(j2, dict) and j2.get("ok"):
                    imported += 1
                else:
                    failed.append((it["chapter"], it["section"], it["body"]["stem"][:30], d2[:150]))

    print("")
    print("===== 完成 =====")
    print("成功导入 %d 题；本地预校验跳过 %d；服务器端逐题失败 %d" % (imported, len(skipped), len(failed)))
    for ch, sec, hint, why in failed[:20]:
        print("  [失败] %s / %s ｜ %s ｜ %s" % (ch, sec, hint, why))
    print("图片目录：%s/<分类id>/<yyyy-mm>/（服务按 /uploads/images/<cid>/<月份>/<name> 访问）" % os.path.abspath(args.upload_dir))
    print("提醒：本工具对专业/分类幂等，但对题目不幂等——重复运行会重复导入题目！")


if __name__ == "__main__":
    main()
