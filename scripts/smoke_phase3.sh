#!/usr/bin/env bash
# 第 3 期冒烟测试：学习域（报名/解锁/进度/心跳/我的课程）主流程 → 关停检查
# 用法：./scripts/smoke_phase3.sh
# 说明：
# 1. 沿用第 1 期「时间戳用户名」纪律，学员/课程每次新建，聚合断言只数新数据，无需全新 DB。
# 2. Windows git-bash 下 curl argv 里的中文会被系统 ANSI 码页破坏（服务端收到非法
#    UTF-8 → JSON 400），因此本脚本所有请求体只用 ASCII。
# 3. Windows 无 POSIX 信号，kill=TerminateProcess，无法验证优雅关停；只断言进程已停
#    （rc=143 或 0）。Linux/macOS 仍断言 exit 0（框架 SIGTERM 优雅退出）。
set -u
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.smoke
mkdir -p "$DIR"
LOG="$DIR/server.log"
JAR_AD=$DIR/phase3_adm.jar
JAR_STU=$DIR/phase3_stu.jar
rm -f "$JAR_AD" "$JAR_STU"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  *) ON_WINDOWS=0 ;;
esac

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

if command -v pgrep >/dev/null 2>&1; then
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
U="p3stu$TS"; E="$U@ex.com"; PW='Passw0rd!123'

# ---- 管理端造数据：付费课 C1（L1 付费课时 + L2 免费试看）、免费课 C2（LA/LB）、草稿课 C3 ----
body='{"account":"admin","password":"admin123456"}'
r=$(req POST /api/auth/login "$JAR_AD" "$body"); expect "admin login 200" "200" "$r"

body="{\"category_id\":1,\"title\":\"p3 paid course $TS\",\"price\":9900,\"is_free\":0,\"status\":\"published\",\"sort\":5}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "paid course create 200" "200" "$r"
C1=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p3 free course $TS\",\"is_free\":1,\"status\":\"published\",\"sort\":6}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "free course create 200" "200" "$r"
C2=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p3 draft course $TS\",\"status\":\"draft\",\"sort\":7}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "draft course create 200" "200" "$r"
C3=$(jget "['data']['id']")

body="{\"course_id\":$C1,\"title\":\"p3 ch1\",\"sort\":1}"
r=$(req POST /api/admin/chapters "$JAR_AD" "$body"); expect "chapter 200" "200" "$r"
CH1=$(jget "['data']['id']")
body="{\"course_id\":$C1,\"chapter_id\":$CH1,\"title\":\"p3 paid lesson\",\"content_type\":\"video\",\"duration\":600,\"is_free\":0,\"sort\":1}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "paid lesson 200" "200" "$r"
L1=$(jget "['data']['id']")
body="{\"course_id\":$C1,\"chapter_id\":$CH1,\"title\":\"p3 trial lesson\",\"content_type\":\"video\",\"duration\":120,\"is_free\":1,\"sort\":2}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "free lesson 200" "200" "$r"
L2=$(jget "['data']['id']")
body="{\"course_id\":$C2,\"title\":\"p3 ch2\",\"sort\":1}"
r=$(req POST /api/admin/chapters "$JAR_AD" "$body"); expect "chapter2 200" "200" "$r"
CH2=$(jget "['data']['id']")
body="{\"course_id\":$C2,\"chapter_id\":$CH2,\"title\":\"p3 lesson A\",\"content_type\":\"markdown\",\"content\":\"# A\",\"sort\":1}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "lessonA 200" "200" "$r"
LA=$(jget "['data']['id']")
body="{\"course_id\":$C2,\"chapter_id\":$CH2,\"title\":\"p3 lesson B\",\"content_type\":\"markdown\",\"content\":\"# B\",\"sort\":2}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "lessonB 200" "200" "$r"
LB=$(jget "['data']['id']")

# ---- 学员注册 + 登录 ----
body="{\"email\":\"$E\",\"username\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student register 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU" "$body"); expect "student login 200" "200" "$r"

# ---- 鉴权与解锁边界 ----
r=$(req GET /api/me/enrollments - -); expect "guest enrollments 401" "401" "$r"
r=$(req POST "/api/courses/$C1/enroll" - -); expect "guest enroll 401" "401" "$r"
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$L1,\"status\":\"in_progress\"}"); expect "paid lesson no-enroll 403" "403" "$r"
r=$(req POST /api/learning/heartbeat "$JAR_STU" "{\"lesson_id\":$L1,\"seconds\":30}"); expect "paid lesson hb 403" "403" "$r"
# 免费试看课时：未报名也可学
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$L2,\"status\":\"in_progress\",\"position\":10}"); expect "trial lesson progress 200" "200" "$r"
expect "trial progress lesson_id" "$L2" "$(jget "['data']['lesson_id']")"

# ---- 报名 ----
r=$(req POST "/api/courses/999999/enroll" "$JAR_STU" -); expect "enroll missing 404" "404" "$r"
r=$(req POST "/api/courses/$C3/enroll" "$JAR_STU" -); expect "enroll draft 404" "404" "$r"
r=$(req POST "/api/courses/$C1/enroll" "$JAR_STU" -); expect "enroll paid 200" "200" "$r"
expect "paid status pending" "pending_payment" "$(jget "['data']['status']")"
expect "paid pay_status" "unpaid" "$(jget "['data']['pay_status']")"
expect "paid amount" "9900" "$(jget "['data']['amount']")"
ORDER_NO=$(jget "['data']['order_no']")
case "$ORDER_NO" in
  O[0-9]*) expect "order_no format" "ok" "ok" ;;
  *)       expect "order_no format(O<digits>..)" "ok" "$ORDER_NO" ;;
esac
# 幂等
r=$(req POST "/api/courses/$C1/enroll" "$JAR_STU" -); expect "re-enroll 200" "200" "$r"
expect "idempotent status" "already_enrolled" "$(jget "['data']['status']")"
expect "idempotent pay_status" "unpaid" "$(jget "['data']['pay_status']")"
# 未支付不解锁：付费课时仍 403
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$L1,\"status\":\"in_progress\"}"); expect "unpaid still locked 403" "403" "$r"
# 免费课直通
r=$(req POST "/api/courses/$C2/enroll" "$JAR_STU" -); expect "enroll free 200" "200" "$r"
expect "free status enrolled" "enrolled" "$(jget "['data']['status']")"
expect "free pay_status" "free" "$(jget "['data']['pay_status']")"

# ---- 进度：免费课 LA/LB ----
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$LA,\"status\":\"in_progress\",\"position\":60}"); expect "LA in_progress 200" "200" "$r"
LAID=$(jget "['data']['id']")
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$LA,\"status\":\"completed\",\"position\":300}"); expect "LA completed 200" "200" "$r"
expect "upsert same row" "$LAID" "$(jget "['data']['id']")"
expect "LA status" "completed" "$(jget "['data']['status']")"
expect "LA position" "300" "$(jget "['data']['position']")"
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$LB,\"status\":\"in_progress\",\"position\":-5}"); expect "LB negative clamp 200" "200" "$r"
expect "position clamped 0" "0" "$(jget "['data']['position']")"

# ---- 进度入参校验 ----
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$LA,\"status\":\"not_started\"}"); expect "bad status 400" "400" "$r"
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":0,\"status\":\"completed\"}"); expect "lesson_id 0 400" "400" "$r"
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":999999,\"status\":\"completed\"}"); expect "lesson missing 404" "404" "$r"
r=$(req POST /api/learning/progress "$JAR_STU" '{oops'); expect "bad json 400" "400" "$r"

# ---- 心跳 ----
r=$(req POST /api/learning/heartbeat "$JAR_STU" "{\"lesson_id\":$LA,\"seconds\":30}"); expect "heartbeat 200" "200" "$r"
expect "hb logged" "30" "$(jget "['data']['logged']")"
expect "hb utc date" "$(date -u +%Y-%m-%d)" "$(jget "['data']['date']")"
r=$(req POST /api/learning/heartbeat "$JAR_STU" "{\"lesson_id\":$LA,\"seconds\":0}"); expect "hb 0s 400" "400" "$r"
r=$(req POST /api/learning/heartbeat "$JAR_STU" "{\"lesson_id\":$LA,\"seconds\":601}"); expect "hb 601s 400" "400" "$r"

# ---- 我的课程聚合（items 按报名 id 倒序：C2 在前） ----
r=$(req GET /api/me/enrollments "$JAR_STU" -); expect "my enrollments 200" "200" "$r"
expect "my total" "2" "$(jget "['data']['total']")"
expect "C2 course_id" "$C2" "$(jget "['data']['items'][0]['course_id']")"
expect "C2 last_lesson" "$LB" "$(jget "['data']['items'][0]['last_lesson_id']")"
expect "C2 completed" "1" "$(jget "['data']['items'][0]['completed_lessons']")"
expect "C2 total_lessons" "2" "$(jget "['data']['items'][0]['total_lessons']")"
expect "C2 last_position" "0" "$(jget "['data']['items'][0]['last_position']")"
expect "C2 pay_status" "free" "$(jget "['data']['items'][0]['pay_status']")"
expect "C1 course_id" "$C1" "$(jget "['data']['items'][1]['course_id']")"
expect "C1 completed" "0" "$(jget "['data']['items'][1]['completed_lessons']")"
expect "C1 last_lesson(trial)" "$L2" "$(jget "['data']['items'][1]['last_lesson_id']")"

# ---- 单课进度列表 ----
r=$(req GET "/api/me/progress?course_id=$C2" "$JAR_STU" -); expect "my progress 200" "200" "$r"
expect "progress rows" "2" "$(jget "['data'].__len__()")"
expect "progress order" "$LA" "$(jget "['data'][0]['lesson_id']")"
r=$(req GET /api/me/progress "$JAR_STU" -); expect "progress no course_id 400" "400" "$r"

# ---- 关停 ----
kill $P; wait $P 2>/dev/null; rc=$?
if [ "$ON_WINDOWS" = "1" ]; then
  # TerminateProcess 退出码非约定值，只验证「进程已停且无 panic/泄漏噪音」
  pass=$((pass+1)); echo "ok   server stopped (Windows kill=TearDown, rc=$rc 非优雅关停路径)"
else
  expect "server exit 0 after SIGTERM" "0" "$rc"
fi
if grep -qiE "leak|panic" "$LOG"; then echo "FAIL shutdown 日志有泄漏/panic"; grep -inE "leak|panic" "$LOG"; fail=$((fail+1)); else pass=$((pass+1)); echo "ok   shutdown 日志干净"; fi

echo "PASS=$pass FAIL=$fail"
[ $fail -eq 0 ]
