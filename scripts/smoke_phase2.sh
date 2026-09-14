#!/usr/bin/env bash
# 第 2 期冒烟测试：分类/课程/章节/课时 + 资料库（上传-下载-管理）主流程 → 关停检查
# 用法：./scripts/smoke_phase2.sh
# 注意：macOS bash 3.2 在「双引号参数里嵌套 $(...) 且内含 \" 转义」时会破坏参数
#       （实测 bug），所有带 JSON 体的请求必须先赋值到变量再断言。
set -u
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.smoke
mkdir -p "$DIR"
LOG="$DIR/server.log"
JAR_AD=$DIR/phase2_adm.jar
rm -f "$JAR_AD"

pass=0; fail=0
req() { # req <method> <path> <jar|- > <json|- > → stdout=状态码，body → $DIR/last.json
  local m=$1 p=$2 jar=$3 data=$4 args=(-s -o "$DIR/last.json" -w "%{http_code}")
  [ "$jar" != "-" ] && args+=(-b "$jar" -c "$jar")
  [ "$data" != "-" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  curl "${args[@]}" -X "$m" "$BASE$p"
}
expect() { # expect <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1 ($3)";
  else fail=$((fail+1)); echo "FAIL $1 expected=$2 got=$3 body=$(head -c 300 "$DIR/last.json" 2>/dev/null)"; fi
}
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval('d'+sys.argv[2]))" "$DIR/last.json" "$1" 2>/dev/null || echo ""; }

LEFT=$(pgrep -x crm || true)
if [ -n "$LEFT" ]; then echo "已有 crm 进程在运行（$LEFT），先停掉它"; exit 1; fi

"$BIN" > "$LOG" 2>&1 &
P=$!
for _ in $(seq 1 60); do
  curl -sf "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done

r=$(req GET /api/health - -); expect "health 200" "200" "$r"

# ---- 超管登录 ----
body='{"account":"admin","password":"admin123456"}'
r=$(req POST /api/auth/login "$JAR_AD" "$body"); expect "admin login 200" "200" "$r"

# ---- 分类（公开树 + 管理端）----
r=$(req GET /api/categories - -); expect "categories tree 200" "200" "$r"
expect "seed root name" "临床执业医师" "$(jget "['data'][0]['name']")"
# 更新/删除用独立临时分类，避免动到种子根（后续所有 create 都依赖 category_id=1）
r=$(req POST /api/admin/categories "$JAR_AD" '{"parent_id":0,"name":"临时分类","sort":93}'); expect "temp cat create 200" "200" "$r"
TCATID=$(jget "['data']['id']")
r=$(req PUT "/api/admin/categories/$TCATID" "$JAR_AD" '{"parent_id":0,"name":"临时分类(改)","sort":93}'); expect "temp cat update 200" "200" "$r"
r=$(req DELETE "/api/admin/categories/$TCATID" "$JAR_AD" -); expect "temp cat delete 200" "200" "$r"

# ---- 课程 CRUD ----
r=$(req POST /api/admin/courses "$JAR_AD" '{"category_id":1,"title":"内科学 课程 A","price":9900,"is_free":0,"status":"published","sort":5}'); expect "course create 200" "200" "$r"
CID=$(jget "['data']['id']")
r=$(req POST /api/admin/courses "$JAR_AD" '{"category_id":1,"title":"课程 B(草稿)","status":"draft","sort":6}'); expect "course create draft 200" "200" "$r"
CIDB=$(jget "['data']['id']")
r=$(req GET /api/admin/courses "$JAR_AD" -); expect "admin courses 200" "200" "$r"
r=$(req PUT "/api/admin/courses/$CID" "$JAR_AD" '{"category_id":1,"title":"课程 A(改)","summary":"目标人群","price":12800,"is_free":0,"status":"published","sort":9}'); expect "course update 200" "200" "$r"
expect "course update title" "课程 A(改)" "$(jget "['data']['title']")"

# ---- 公开端只显示 published ----
r=$(req GET "/api/courses?keyword=%E8%AF%BE%E7%A8%8B%20B" - -); expect "draft hidden 0" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/courses/$CIDB" - -); expect "draft detail 404" "404" "$r"
r=$(req GET "/api/courses/$CID" - -); expect "public detail 200" "200" "$r"

# ---- 章节/课时 ----
r=$(req POST /api/admin/chapters "$JAR_AD" "{\"course_id\":$CID,\"title\":\"第一章 绪论\",\"sort\":1}"); expect "chapter create 200" "200" "$r"
CHID=$(jget "['data']['id']")
r=$(req POST /api/admin/lessons "$JAR_AD" "{\"course_id\":$CID,\"chapter_id\":$CHID,\"title\":\"课时 1 导学\",\"content_type\":\"video\",\"duration\":300,\"is_free\":0,\"sort\":1}"); expect "lesson create 200" "200" "$r"
LID=$(jget "['data']['id']")
r=$(req PUT "/api/admin/lessons/$LID" "$JAR_AD" "{\"course_id\":$CID,\"chapter_id\":$CHID,\"title\":\"课时 1 导学(改)\",\"content_type\":\"markdown\",\"content\":\"# 题干\",\"duration\":300,\"is_free\":0,\"sort\":1}"); expect "lesson update 200" "200" "$r"
r=$(req DELETE "/api/admin/lessons/$LID" "$JAR_AD" -); expect "lesson delete 200" "200" "$r"

# ---- 资料库上传（multipart）----
printf 'crm 冒烟资料内容 1234567890' > "$DIR/up.txt"
r=$(curl -s -o "$DIR/last.json" -w "%{http_code}" -X POST "$BASE/api/admin/upload" -b "$JAR_AD" -c "$JAR_AD" -F "file=@$DIR/up.txt;type=text/plain" -F "name=冒烟讲义" -F "category_id=1" -F "is_public=1"); expect "upload 200" "200" "$r"
RID=$(jget "['data']['id']")
# 公开下载
r=$(curl -s -o "$DIR/dl.txt" -w "%{http_code}" "$BASE/api/resources/$RID/download"); expect "download 200" "200" "$r"
expect "download bytes" "crm 冒烟资料内容 1234567890" "$(cat "$DIR/dl.txt")"
r=$(curl -s -o "$DIR/dl2.txt" -w "%{http_code}" "$BASE/api/resources/99999/download"); expect "download missing 404" "404" "$r"

# 私密资料：游客下载被拒
printf '私密内容' > "$DIR/up2.txt"
r=$(curl -s -o "$DIR/last.json" -w "%{http_code}" -X POST "$BASE/api/admin/upload" -b "$JAR_AD" -c "$JAR_AD" -F "file=@$DIR/up2.txt;type=text/plain" -F "name=内部资料" -F "category_id=1" -F "is_public=0"); expect "upload private 200" "200" "$r"
RIDP=$(jget "['data']['id']")
r=$(curl -s -o "$DIR/last.json" -w "%{http_code}" "$BASE/api/resources/$RIDP/download"); expect "private guest 401" "401" "$r"

# 公开列表：游客只见公开
r=$(req GET /api/resources - -); expect "public list 200" "200" "$r"
expect "public only 1" "1" "$(jget "['data']['total']")"

# 管理端列表/元数据维护/删除
r=$(req GET /api/admin/resources "$JAR_AD" -); expect "admin list 200" "200" "$r"
r=$(req GET "/api/admin/resources/99999" "$JAR_AD" -); expect "admin get missing 404" "404" "$r"
r=$(req POST /api/admin/resources "$JAR_AD" "{\"category_id\":1,\"name\":\"元数据资源\",\"orig_name\":\"meta.txt\",\"rtype\":\"doc\",\"file_path\":\"uploads/2026-09/meta.txt\",\"size\":4,\"mime\":\"text/plain\",\"is_public\":1}"); expect "meta create 200" "200" "$r"
RIDM=$(jget "['data']['id']")
r=$(req DELETE "/api/admin/resources/$RIDM" "$JAR_AD" -); expect "meta delete 200" "200" "$r"
r=$(req GET "/api/admin/resources/$RIDM" "$JAR_AD" -); expect "meta get after delete 404" "404" "$r"

# ---- 分类删除校验：父类有子分类 → 409；删光子类后 → 200 ----
r=$(req POST /api/admin/categories "$JAR_AD" '{"parent_id":0,"name":"父分类","sort":92}'); expect "parent cat 200" "200" "$r"
PCAT=$(jget "['data']['id']")
r=$(req POST /api/admin/categories "$JAR_AD" "{\"parent_id\":$PCAT,\"name\":\"子分类 A\",\"sort\":1}"); expect "child cat 200" "200" "$r"
CCAT=$(jget "['data']['id']")
r=$(req POST /api/admin/categories "$JAR_AD" "{\"parent_id\":$PCAT,\"name\":\"子分类 B\",\"sort\":2}"); expect "child cat B 200" "200" "$r"
CCATB=$(jget "['data']['id']")
r=$(req DELETE "/api/admin/categories/$PCAT" "$JAR_AD" -); expect "delete parent w children 409" "409" "$r"
r=$(req DELETE "/api/admin/categories/$CCAT" "$JAR_AD" -); expect "delete child A 200" "200" "$r"
r=$(req DELETE "/api/admin/categories/$CCATB" "$JAR_AD" -); expect "delete child B 200" "200" "$r"
r=$(req DELETE "/api/admin/categories/$PCAT" "$JAR_AD" -); expect "delete parent now 200" "200" "$r"

# ---- 关停：退出码 + 泄漏检查 ----
kill $P; wait $P 2>/dev/null; rc=$?
expect "server exit 0 after SIGTERM" "0" "$rc"
if grep -qiE "leak|panic" "$LOG"; then echo "FAIL shutdown 日志有泄漏/panic"; grep -inE "leak|panic" "$LOG"; fail=$((fail+1)); else pass=$((pass+1)); echo "ok   shutdown 日志干净"; fi

echo "PASS=$pass FAIL=$fail"
[ $fail -eq 0 ]
