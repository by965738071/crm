#!/usr/bin/env bash
# 第 7 期冒烟测试：公告（状态机/公开隐身/检索/权限）+ 收藏（幂等/隐身/越权/DELETE带body）
#               + 笔记（归属校验/本人隔离）+ 后台统计（相对增量）→ 关停检查
# 用法：./scripts/smoke_phase7.sh
# 说明：
# 1. 沿用「时间戳用户名 + keyword/用户过滤」纪律：统计用 before/after 相对增量断言，
#    不受历史运行数据干扰。
# 2. Windows git-bash 下 curl argv 中文会被码页破坏 → 所有请求体只用 ASCII。
# 3. 收藏 add 用 JSON body；remove 走 query 参数（框架协议层拒绝 DELETE 带 body，见 Issue 5）。
#    原「DELETE 带 body 能力」验证点转为：显式断言框架拒收 DELETE+CL 头请求（400）。
# 4. Windows 无 POSIX 信号，kill=TerminateProcess（rc=143）；Linux/macOS 断言 exit 0。
set -u
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.smoke
mkdir -p "$DIR"
LOG="$DIR/server.log"
JAR_AD=$DIR/phase7_adm.jar
JAR_STU=$DIR/phase7_stu.jar
JAR_STU2=$DIR/phase7_stu2.jar
rm -f "$JAR_AD" "$JAR_STU" "$JAR_STU2" "$DIR/reqlog.txt"
rm -rf "$DIR/b"; mkdir -p "$DIR/b"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  *) ON_WINDOWS=0 ;;
esac

pass=0; fail=0
lastf() { echo "$DIR/b/$(ls -1 "$DIR/b" 2>/dev/null | wc -l).json"; }
req() { # req <method> <path> <jar|- > <json|- > → stdout=状态码，body → $(lastf)
  local m=$1 p=$2 jar=$3 data=$4
  local lastf_="$DIR/b/$(( $(ls -1 "$DIR/b" 2>/dev/null | wc -l) + 1 )).json"
  local args=(-s -w "%{http_code}" -o "$lastf_")
  [ "$jar" != "-" ] && args+=(-b "$jar" -c "$jar")
  # 注：框架对 GET/HEAD/DELETE 携带 Content-Length>0 的 body 直接 400（防走私），
  #       带 body 的写接口一律用 POST/PUT；取消收藏走 query 参数。
  [ "$data" != "-" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  local code=$(curl "${args[@]}" -X "$m" "$BASE$p" 2>/dev/null)
  [ -s "$lastf_" ] || { mkdir -p "$DIR/b"; echo BODY_WRITE_MISS > "$lastf_" 2>/dev/null; }
  { printf '%s %s %s ' "$m" "$p" "$code"; head -c 120 "$lastf_" 2>/dev/null | tr -d '\n'; echo; } >> "$DIR/reqlog.txt"
  echo "$code"
}
expect() { # expect <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1 ($3)";
  else fail=$((fail+1)); echo "FAIL $1 expected=$2 got=$3 body=$(head -c 300 "$(lastf)" 2>/dev/null)"; fi
}
# 错误体是 text/plain（框架 ErrorRenderer）→ 用 grep 断言文案而非 json.load
expectgrep() { # expectgrep <desc> <pattern>
  if grep -q "$2" "$(lastf)" 2>/dev/null; then pass=$((pass+1)); echo "ok   $1";
  else fail=$((fail+1)); echo "FAIL $1 pattern=$2 body=$(head -c 300 "$(lastf)" 2>/dev/null)"; fi
}
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(eval('d'+sys.argv[2]))" "$(lastf)" "$1" 2>/dev/null || echo ""; }
jexpr() { python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(eval(sys.argv[2]))" "$(lastf)" "$1" 2>/dev/null || echo ""; }

if command -p pgrep >/dev/null 2>&1; then
  LEFT=$(pgrep -x crm || true)
  if [ -n "$LEFT" ]; then echo "已有 crm 进程在运行（$LEFT），先停掉它"; exit 1; fi
fi

"$BIN" > "$LOG" 2>&1 &
P=$!
for _ in $(seq 1 60); do
  curl -sf "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done

r=$(req GET /api/health - -); expect "health 200" "200" "$r"

TS=$(date +%s)
U="p7stu$TS"; E="$U@ex.com"; PW='Passw0rd!123'
U2="p7stuB$TS"; E2="$U2@ex.com"

body='{"account":"admin","password":"admin123456"}'
r=$(req POST /api/auth/login "$JAR_AD" "$body"); expect "admin login 200" "200" "$r"

# ---- 学员注册 + 登录 ----
body="{\"email\":\"$E\",\"username\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student1 register 200" "200" "$r"
body="{\"email\":\"$E2\",\"username\":\"$U2\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student2 register 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU" "$body"); expect "student1 login 200" "200" "$r"
STUID=$(jget "['data']['id']")
body="{\"account\":\"$U2\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU2" "$body"); expect "student2 login 200" "200" "$r"

# ---- 素材：课程 C1（付费）+ 章节 + 免费课时 L1；C2（后续软删验证收藏隐身）；C3 + 课时 L3（验证 lesson 归属）----
body="{\"category_id\":1,\"title\":\"p7c1$TS\",\"price\":9900,\"is_free\":0,\"status\":\"published\",\"sort\":5}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course C1 200" "200" "$r"
C1=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p7c2$TS\",\"price\":100,\"is_free\":0,\"status\":\"published\",\"sort\":5}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course C2 200" "200" "$r"
C2=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p7c3$TS\",\"is_free\":1,\"status\":\"published\",\"sort\":6}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course C3 200" "200" "$r"
C3=$(jget "['data']['id']")
body="{\"course_id\":$C1,\"title\":\"p7 ch1\",\"sort\":1}"
r=$(req POST /api/admin/chapters "$JAR_AD" "$body"); expect "chapter CH1 200" "200" "$r"
CH1=$(jget "['data']['id']")
body="{\"course_id\":$C1,\"chapter_id\":$CH1,\"title\":\"p7 lesson1\",\"content_type\":\"video\",\"duration\":600,\"is_free\":1,\"sort\":1}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "lesson L1 200" "200" "$r"
L1=$(jget "['data']['id']")
body="{\"course_id\":$C3,\"title\":\"p7 ch3\",\"sort\":1}"
r=$(req POST /api/admin/chapters "$JAR_AD" "$body"); expect "chapter CH3 200" "200" "$r"
CH3=$(jget "['data']['id']")
body="{\"course_id\":$C3,\"chapter_id\":$CH3,\"title\":\"p7 lesson3\",\"content_type\":\"video\",\"duration\":300,\"is_free\":1,\"sort\":1}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "lesson L3 200" "200" "$r"
L3=$(jget "['data']['id']")
body="{\"category_id\":1,\"name\":\"p7r1$TS\",\"orig_name\":\"p7.txt\",\"rtype\":\"doc\",\"file_path\":\"uploads/p7.txt\",\"size\":4,\"mime\":\"text/plain\",\"is_public\":1}"
r=$(req POST /api/admin/resources "$JAR_AD" "$body"); expect "resource R1 meta 200" "200" "$r"
R1=$(jget "['data']['id']")

# ==================================================================== 公告
KW="p7ann$TS"

r=$(req POST /api/admin/announcements "$JAR_AD" "{\"title\":\"$KW A1\",\"content\":\"alpha content\",\"status\":\"draft\"}"); expect "ann A1 create 200" "200" "$r"
A1=$(jget "['data']['id']")
expect "A1 status draft" "draft" "$(jget "['data']['status']")"
expect "A1 published_at 0" "0" "$(jget "['data']['published_at']")"

# 草稿：公开端列表/详情都隐身
r=$(req GET "/api/announcements?keyword=$KW" - -); expect "public hides draft" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/announcements/$A1" - -); expect "guest draft detail 404" "404" "$r"
r=$(req GET "/api/announcements/$A1" "$JAR_STU" -); expect "student draft detail 404" "404" "$r"

r=$(req POST "/api/admin/announcements/$A1/publish" "$JAR_AD" -); expect "A1 publish 200" "200" "$r"
expect "A1 status published" "published" "$(jget "['data']['status']")"
r=$(req POST "/api/admin/announcements/$A1/publish" "$JAR_AD" -); expect "A1 re-publish 400" "400" "$r"

r=$(req GET "/api/announcements?keyword=$KW" - -); expect "public shows published" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/announcements/$A1" "$JAR_STU" -); expect "student published detail 200" "200" "$r"
expect "detail title" "$KW A1" "$(jget "['data']['title']")"

# 更新文案不动状态
r=$(req PUT "/api/admin/announcements/$A1" "$JAR_AD" "{\"title\":\"$KW A1v2\",\"content\":\"beta content\"}"); expect "A1 update 200" "200" "$r"
expect "A1 title updated" "$KW A1v2" "$(jget "['data']['title']")"
expect "A1 status untouched" "published" "$(jget "['data']['status']")"

r=$(req POST "/api/admin/announcements/$A1/unpublish" "$JAR_AD" -); expect "A1 unpublish 200" "200" "$r"
r=$(req GET "/api/announcements?keyword=$KW" - -); expect "public hides again after unpublish" "0" "$(jget "['data']['total']")"
r=$(req POST "/api/admin/announcements/$A1/unpublish" "$JAR_AD" -); expect "A1 re-unpublish 400" "400" "$r"
r=$(req POST "/api/admin/announcements/$A1/publish" "$JAR_AD" -); expect "A1 publish again 200" "200" "$r"

# A2 草稿：status 过滤 + 正文关键词检索
KW2="bodykwtst$TS"
r=$(req POST /api/admin/announcements "$JAR_AD" "{\"title\":\"$KW A2\",\"content\":\"zz $KW2 zz\",\"status\":\"draft\"}"); expect "ann A2 create 200" "200" "$r"
A2=$(jget "['data']['id']")
r=$(req GET "/api/admin/announcements?status=draft&keyword=$KW" "$JAR_AD" -); expect "admin draft-only count 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/announcements?keyword=$KW" "$JAR_AD" -); expect "admin all count 2" "2" "$(jget "['data']['total']")"
r=$(req GET "/api/announcements?keyword=$KW2" - -); expect "body keyword hides draft" "0" "$(jget "['data']['total']")"
r=$(req POST "/api/admin/announcements/$A2/publish" "$JAR_AD" -); expect "A2 publish 200" "200" "$r"
r=$(req GET "/api/announcements?keyword=$KW2" - -); expect "body keyword finds published" "1" "$(jget "['data']['total']")"

r=$(req GET "/api/admin/announcements/$A2" "$JAR_AD" -); expect "admin get A2 200" "200" "$r"
r=$(req GET "/api/admin/announcements?status=bogus" "$JAR_AD" -); expect "bad status filter 400" "400" "$r"
r=$(req GET /api/admin/announcements "$JAR_STU" -); expect "student admin list 403" "403" "$r"
r=$(req GET /api/admin/announcements - -); expect "guest admin list 401" "401" "$r"
r=$(req GET /api/announcements - -); expect "guest public list 200" "200" "$r"

r=$(req POST /api/admin/announcements "$JAR_AD" "{\"title\":\"\",\"content\":\"x\"}"); expect "empty title 400" "400" "$r"

# 删除 A1 → 全隐身 + 终态
r=$(req DELETE "/api/admin/announcements/$A1" "$JAR_AD" -); expect "A1 delete 200" "200" "$r"
r=$(req GET "/api/announcements/$A1" - -); expect "A1 public detail 404" "404" "$r"
r=$(req GET "/api/admin/announcements/$A1" "$JAR_AD" -); expect "A1 admin get 404" "404" "$r"
r=$(req PUT "/api/admin/announcements/$A1" "$JAR_AD" "{\"title\":\"t\",\"content\":\"c\"}"); expect "A1 update deleted 404" "404" "$r"
r=$(req POST "/api/admin/announcements/$A1/publish" "$JAR_AD" -); expect "A1 publish deleted 404" "404" "$r"
r=$(req DELETE "/api/admin/announcements/$A1" "$JAR_AD" -); expect "A1 re-delete 404" "404" "$r"

# ==================================================================== 收藏

r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"course\",\"target_id\":$C1}"); expect "fav add C1 200" "200" "$r"
r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"course\",\"target_id\":$C1}"); expect "fav add C1 dup 200" "200" "$r"
r=$(req GET /api/favorites "$JAR_STU" -); expect "fav total 1" "1" "$(jget "['data']['total']")"
expect "fav item course title" "p7c1$TS" "$(jget "['data']['items'][0]['title']")"

r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"resource\",\"target_id\":$R1}"); expect "fav add R1 200" "200" "$r"
r=$(req GET /api/favorites "$JAR_STU" -); expect "fav total 2" "2" "$(jget "['data']['total']")"
r=$(req GET "/api/favorites?target_type=course" "$JAR_STU" -); expect "fav filter course 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/favorites?target_type=resource" "$JAR_STU" -); expect "fav filter resource 1" "1" "$(jget "['data']['total']")"
expect "fav item resource title" "p7r1$TS" "$(jget "['data']['items'][0]['title']")"

r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"bogus\",\"target_id\":1}"); expect "fav bad type 400" "400" "$r"
r=$(req DELETE "/api/favorites?target_type=bogus&target_id=1" "$JAR_STU" -); expect "fav remove bad type 400" "400" "$r"
r=$(req DELETE "/api/favorites?target_type=course&target_id=abc" "$JAR_STU" -); expect "fav remove bad id 400" "400" "$r"
r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"course\",\"target_id\":999999}"); expect "fav missing course 404" "404" "$r"
r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"resource\",\"target_id\":999999}"); expect "fav missing resource 404" "404" "$r"
r=$(req GET "/api/favorites?target_type=bogus" "$JAR_STU" -); expect "fav filter bad type 400" "400" "$r"
r=$(req POST /api/favorites - "{\"target_type\":\"course\",\"target_id\":$C1}"); expect "fav guest 401" "401" "$r"
# 框架对 DELETE+body 协议层拒收（400，见 http-framework-issues.md Issue 5），断言固化该行为
r=$(req DELETE /api/favorites "$JAR_STU" "{\"target_type\":\"course\",\"target_id\":1}"); expect "DELETE with body rejected 400" "400" "$r"

# DELETE + JSON body（重点验证框架读取 DELETE 请求体的能力）
r=$(req DELETE "/api/favorites?target_type=course&target_id=$C1" "$JAR_STU" -); expect "fav remove C1 200" "200" "$r"
r=$(req GET /api/favorites "$JAR_STU" -); expect "fav total after remove 1" "1" "$(jget "['data']['total']")"
r=$(req DELETE "/api/favorites?target_type=course&target_id=$C1" "$JAR_STU" -); expect "fav remove again 404" "404" "$r"
r=$(req DELETE "/api/favorites?target_type=resource&target_id=$R1" "$JAR_STU2" -); expect "fav remove others 404" "404" "$r"
r=$(req GET /api/favorites "$JAR_STU2" -); expect "fav stu2 isolated 0" "0" "$(jget "['data']['total']")"

# 收藏 C2 → 删除课程 → 收藏隐身
r=$(req POST /api/favorites "$JAR_STU" "{\"target_type\":\"course\",\"target_id\":$C2}"); expect "fav add C2 200" "200" "$r"
r=$(req GET /api/favorites "$JAR_STU" -); expect "fav total with C2 2" "2" "$(jget "['data']['total']")"
r=$(req DELETE "/api/admin/courses/$C2" "$JAR_AD" -); expect "admin delete C2 200" "200" "$r"
r=$(req GET /api/favorites "$JAR_STU" -); expect "fav hides deleted course" "1" "$(jget "['data']['total']")"
r=$(req DELETE "/api/favorites?target_type=resource&target_id=$R1" "$JAR_STU" -); expect "fav remove R1 200" "200" "$r"
r=$(req GET /api/favorites "$JAR_STU" -); expect "fav empty at end" "0" "$(jget "['data']['total']")"

# ==================================================================== 笔记

r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":$C1,\"lesson_id\":$L1,\"content\":\"p7note one\"}"); expect "note create 200" "200" "$r"
NID=$(jget "['data']['id']")
expect "note course_title" "p7c1$TS" "$(jget "['data']['course_title']")"
expect "note lesson_title" "p7 lesson1" "$(jget "['data']['lesson_title']")"

r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":$C1,\"content\":\"\"}"); expect "note empty content 400" "400" "$r"
r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":999999,\"content\":\"x\"}"); expect "note missing course 404" "404" "$r"
r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":0,\"content\":\"x\"}"); expect "note course_id 0 400" "400" "$r"
r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":$C1,\"lesson_id\":$L3,\"content\":\"x\"}"); expect "note lesson wrong course 400" "400" "$r"
r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":$C1,\"lesson_id\":999999,\"content\":\"x\"}"); expect "note missing lesson 404" "404" "$r"
r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":$C3,\"lesson_id\":$L3,\"content\":\"p7note lesson3\"}"); expect "note create NID2 200" "200" "$r"
NID2=$(jget "['data']['id']")
r=$(req POST /api/notes "$JAR_STU" "{\"course_id\":$C1,\"content\":\"p7note course level\"}"); expect "note create NID3 200" "200" "$r"
NID3=$(jget "['data']['id']")
r=$(req POST /api/notes - "{\"course_id\":$C1,\"content\":\"x\"}"); expect "note guest 401" "401" "$r"

r=$(req GET "/api/notes?course_id=$C1" "$JAR_STU" -); expect "notes by course 2" "2" "$(jget "['data']['total']")"
r=$(req GET "/api/notes?lesson_id=$L1" "$JAR_STU" -); expect "notes by lesson 1" "1" "$(jget "['data']['total']")"
r=$(req GET /api/notes "$JAR_STU" -); expect "notes all 3" "3" "$(jget "['data']['total']")"
r=$(req GET /api/notes "$JAR_STU2" -); expect "notes stu2 isolated 0" "0" "$(jget "['data']['total']")"

r=$(req PUT "/api/notes/$NID" "$JAR_STU" "{\"content\":\"p7note one v2\"}"); expect "note update 200" "200" "$r"
expect "note content v2" "p7note one v2" "$(jget "['data']['content']")"
expect "note timestamps ordered" "1" "$(jexpr "1 if d['data']['created_at'] <= d['data']['updated_at'] else 0")"
r=$(req PUT "/api/notes/999999" "$JAR_STU" "{\"content\":\"x\"}"); expect "note update missing 404" "404" "$r"
r=$(req PUT "/api/notes/$NID" "$JAR_STU2" "{\"content\":\"hijack\"}"); expect "note update others 404" "404" "$r"
r=$(req PUT "/api/notes/$NID" "$JAR_STU" "{\"content\":\"\"}"); expect "note update empty 400" "400" "$r"

r=$(req DELETE "/api/notes/$NID2" "$JAR_STU2" -); expect "note delete others 404" "404" "$r"
r=$(req DELETE "/api/notes/$NID2" "$JAR_STU" -); expect "note delete NID2 200" "200" "$r"
r=$(req DELETE "/api/notes/$NID2" "$JAR_STU" -); expect "note delete again 404" "404" "$r"
r=$(req GET "/api/notes?course_id=$C3" "$JAR_STU" -); expect "notes C3 after delete 0" "0" "$(jget "['data']['total']")"

# ==================================================================== 统计

r=$(req GET /api/admin/stats - -); expect "stats guest 401" "401" "$r"
r=$(req GET /api/admin/stats "$JAR_STU" -); expect "stats student 403" "403" "$r"
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats 200" "200" "$r"
S_users=$(jget "['data']['users']"); S_today=$(jget "['data']['users_today']")
S_7d=$(jget "['data']['users_7d']"); S_courses=$(jget "['data']['courses']")
S_q=$(jget "['data']['questions']"); S_pending=$(jget "['data']['orders_pending']")
expect "stats fields positive" "1" "$(jexpr "1 if d['data']['users'] > 0 else 0")"

U3="p7stuC$TS"; E3="$U3@ex.com"
r=$(req POST /api/auth/register - "{\"email\":\"$E3\",\"username\":\"$U3\",\"password\":\"$PW\"}"); expect "stats: register new student" "200" "$r"
STU3ID=$(jget "['data']['id']")
r=$(req GET /api/admin/stats "$JAR_AD" -)
expect "stats users +1" "$((S_users+1))" "$(jget "['data']['users']")"
expect "stats users_today +1" "$((S_today+1))" "$(jget "['data']['users_today']")"
expect "stats users_7d +1" "$((S_7d+1))" "$(jget "['data']['users_7d']")"

# 建题 → questions +1 → 删除回基线
r=$(req POST /api/admin/questions "$JAR_AD" "{\"category_id\":1,\"type\":\"single\",\"stem\":\"p7 stat q\",\"options\":[\"a\",\"b\"],\"answer\":\"A\"}"); expect "stats: create question" "200" "$r"
SID=$(jget "['data']['id']")
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats questions +1" "$((S_q+1))" "$(jget "['data']['questions']")"
r=$(req DELETE "/api/admin/questions/$SID" "$JAR_AD" -); expect "stats: delete question" "200" "$r"
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats questions back" "$S_q" "$(jget "['data']['questions']")"

# 建课 → courses +1 → 软删回基线
r=$(req POST /api/admin/courses "$JAR_AD" "{\"category_id\":1,\"title\":\"p7cst$TS\",\"is_free\":1,\"status\":\"published\",\"sort\":9}"); expect "stats: create course" "200" "$r"
SC=$(jget "['data']['id']")
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats courses +1" "$((S_courses+1))" "$(jget "['data']['courses']")"
r=$(req DELETE "/api/admin/courses/$SC" "$JAR_AD" -); expect "stats: delete course" "200" "$r"
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats courses back" "$S_courses" "$(jget "['data']['courses']")"

# 代下单 pending +1 → 取消回基线
r=$(req POST /api/admin/orders "$JAR_AD" "{\"user_id\":$STU3ID,\"course_id\":$C1}"); expect "stats: proxy order" "200" "$r"
SORD=$(jget "['data']['id']")
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats pending +1" "$((S_pending+1))" "$(jget "['data']['orders_pending']")"
r=$(req POST "/api/admin/orders/$SORD/cancel" "$JAR_AD" "{}"); expect "stats: cancel order" "200" "$r"
r=$(req GET /api/admin/stats "$JAR_AD" -); expect "stats pending back" "$S_pending" "$(jget "['data']['orders_pending']")"

# ---- 关停 ----
kill $P; wait $P 2>/dev/null; rc=$?
if [ "$ON_WINDOWS" = "1" ]; then
  pass=$((pass+1)); echo "ok   server stopped (Windows kill=TearDown, rc=$rc 非优雅关停路径)"
else
  expect "server exit 0 after SIGTERM" "0" "$rc"
fi
if grep -qiE "leak|panic" "$LOG"; then echo "FAIL shutdown 日志有泄漏/panic"; grep -inE "leak|panic" "$LOG"; fail=$((fail+1)); else pass=$((pass+1)); echo "ok   shutdown 日志干净"; fi

echo "PASS=$pass FAIL=$fail"
[ $fail -eq 0 ]
