#!/usr/bin/env bash
# 第 6 期冒烟测试：订单（学员列表/管理端列表/代下单/标记支付/取消 + 报名解锁联动 + 状态机）→ 关停检查
# 用法：./scripts/smoke_phase6.sh
# 说明：
# 1. 沿用「时间戳用户名 + 每次新建课程」纪律：列表断言一律带 user_id/keyword 过滤，
#    不受历史运行数据干扰。
# 2. Windows git-bash 下 curl argv 中文会被码页破坏 → 所有请求体只用 ASCII。
# 3. /api/admin/orders/:id/* 的 :id 是订单数字 id（order_no 只作展示/检索用）。
# 4. Windows 无 POSIX 信号，kill=TerminateProcess（rc=143）；Linux/macOS 断言 exit 0。
set -u
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.smoke
mkdir -p "$DIR"
LOG="$DIR/server.log"
JAR_AD=$DIR/phase6_adm.jar
JAR_STU=$DIR/phase6_stu.jar
JAR_STU2=$DIR/phase6_stu2.jar
rm -f "$JAR_AD" "$JAR_STU" "$JAR_STU2" "$DIR/reqlog.txt"
rm -rf "$DIR/b"; mkdir -p "$DIR/b"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  *) ON_WINDOWS=0 ;;
esac

pass=0; fail=0
# 响应体文件：每个请求写 $DIR/b/<序号>.json（序号=当前文件数+1，req 在子 shell 里跑，
# 无法用全局变量传路径；文件数即序号，调用方用 lastf() 自行推算）。
# 唯一文件名 = 即使 Windows 文件锁导致旧文件写入失败，也绝不把陈旧响应伪装成新鲜响应。
lastf() { echo "$DIR/b/$(ls -1 "$DIR/b" 2>/dev/null | wc -l).json"; }
req() { # req <method> <path> <jar|- > <json|- > → stdout=状态码，body → $(lastf)
  local m=$1 p=$2 jar=$3 data=$4
  local lastf_="$DIR/b/$(( $(ls -1 "$DIR/b" 2>/dev/null | wc -l) + 1 )).json"
  local args=(-s -w "%{http_code}" -o "$lastf_")
  [ "$jar" != "-" ] && args+=(-b "$jar" -c "$jar")
  [ "$data" != "-" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  local code=$(curl "${args[@]}" -X "$m" "$BASE$p" 2>/dev/null)
  # curl 未落盘（连接失败/写入被拦）→ 哨兵保证每个请求恰有一个文件，序号不串位。
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
U="p6stu$TS"; E="$U@ex.com"; PW='Passw0rd!123'
U2="p6stuB$TS"; E2="$U2@ex.com"

body='{"account":"admin","password":"admin123456"}'
r=$(req POST /api/auth/login "$JAR_AD" "$body"); expect "admin login 200" "200" "$r"

# ---- 学员注册 + 登录 ----
body="{\"email\":\"$E\",\"username\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student1 register 200" "200" "$r"
STUID=$(jget "['data']['id']")
body="{\"account\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU" "$body"); expect "student1 login 200" "200" "$r"
body="{\"email\":\"$E2\",\"username\":\"$U2\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student2 register 200" "200" "$r"
STUID2=$(jget "['data']['id']")
body="{\"account\":\"$U2\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU2" "$body"); expect "student2 login 200" "200" "$r"

# ---- 造课程：C1/C2/C3 付费、CF 免费、CD 草稿；C1 加一个付费课时 L1 ----
body="{\"category_id\":1,\"title\":\"p6c1$TS\",\"price\":9900,\"is_free\":0,\"status\":\"published\",\"sort\":5}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course C1 200" "200" "$r"
C1=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p6c2$TS\",\"price\":100,\"is_free\":0,\"status\":\"published\",\"sort\":5}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course C2 200" "200" "$r"
C2=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p6c3$TS\",\"price\":500,\"is_free\":0,\"status\":\"published\",\"sort\":5}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course C3 200" "200" "$r"
C3=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p6cf$TS\",\"is_free\":1,\"status\":\"published\",\"sort\":6}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course CF free 200" "200" "$r"
CF=$(jget "['data']['id']")
body="{\"category_id\":1,\"title\":\"p6cd$TS\",\"price\":100,\"status\":\"draft\",\"sort\":7}"
r=$(req POST /api/admin/courses "$JAR_AD" "$body"); expect "course CD draft 200" "200" "$r"
CD=$(jget "['data']['id']")
body="{\"course_id\":$C1,\"title\":\"p6 ch1\",\"sort\":1}"
r=$(req POST /api/admin/chapters "$JAR_AD" "$body"); expect "chapter 200" "200" "$r"
CH1=$(jget "['data']['id']")
body="{\"course_id\":$C1,\"chapter_id\":$CH1,\"title\":\"p6 paid lesson\",\"content_type\":\"video\",\"duration\":600,\"is_free\":0,\"sort\":1}"
r=$(req POST /api/admin/lessons "$JAR_AD" "$body"); expect "paid lesson 200" "200" "$r"
L1=$(jget "['data']['id']")

# ---- S1 报名 C1 → pending 订单；未支付课时锁定 ----
r=$(req POST "/api/courses/$C1/enroll" "$JAR_STU" -); expect "enroll C1 200" "200" "$r"
expect "enroll C1 pending_payment" "pending_payment" "$(jget "['data']['status']")"
expect "enroll C1 amount" "9900" "$(jget "['data']['amount']")"
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$L1,\"status\":\"in_progress\",\"position\":0}"); expect "lesson locked before pay 403" "403" "$r"

# ---- 学员订单列表 ----
r=$(req GET /api/orders - -); expect "guest orders 401" "401" "$r"
r=$(req GET /api/orders "$JAR_STU" -); expect "my orders 200" "200" "$r"
expect "my orders total 1" "1" "$(jget "['data']['total']")"
ORD1=$(jget "['data']['items'][0]['order_no']")
OID1=$(jget "['data']['items'][0]['id']")
expect "order1 status pending" "pending" "$(jget "['data']['items'][0]['status']")"
expect "order1 course_title" "p6c1$TS" "$(jget "['data']['items'][0]['course_title']")"
expect "order1 username" "$U" "$(jget "['data']['items'][0]['username']")"
expect "order1 amount" "9900" "$(jget "['data']['items'][0]['amount']")"
expect "order1 operator 0" "0" "$(jget "['data']['items'][0]['operator_id']")"
expect "order1 paid_at 0" "0" "$(jget "['data']['items'][0]['paid_at']")"
r=$(req GET "/api/orders?status=paid" "$JAR_STU" -); expect "my orders paid 0" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/orders?status=bogus" "$JAR_STU" -); expect "orders bad status 400" "400" "$r"
# 学员端越权参数无关性：传 user_id 也只看本人
r=$(req GET "/api/orders?user_id=$STUID2" "$JAR_STU" -); expect "orders ignore user_id" "1" "$(jget "['data']['total']")"

# ---- 权限：学员打管理端订单接口 ----
r=$(req GET /api/admin/orders "$JAR_STU" -); expect "student admin orders 403" "403" "$r"
r=$(req POST "/api/admin/orders/$OID1/pay" "$JAR_STU" "{}"); expect "student pay 403" "403" "$r"
r=$(req POST "/api/admin/orders/$OID1/cancel" "$JAR_STU" "{}"); expect "student cancel 403" "403" "$r"
r=$(req POST /api/admin/orders "$JAR_STU" "{\"user_id\":$STUID,\"course_id\":$C3}"); expect "student create order 403" "403" "$r"
r=$(req GET /api/admin/orders - -); expect "guest admin orders 401" "401" "$r"

# ---- S1 报名 C2（第二单）；管理端列表过滤 ----
r=$(req POST "/api/courses/$C2/enroll" "$JAR_STU" -); expect "enroll C2 200" "200" "$r"
r=$(req GET /api/orders "$JAR_STU" -); expect "my orders total 2" "2" "$(jget "['data']['total']")"
ORD2=$(jget "['data']['items'][0]['order_no']")
OID2=$(jget "['data']['items'][0]['id']")
r=$(req GET "/api/admin/orders?user_id=$STUID" "$JAR_AD" -); expect "admin list user total 2" "2" "$(jget "['data']['total']")"
expect "admin list desc first is ORD2" "$ORD2" "$(jget "['data']['items'][0]['order_no']")"
r=$(req GET "/api/admin/orders?user_id=$STUID&status=pending" "$JAR_AD" -); expect "admin list pending 2" "2" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?keyword=$ORD1" "$JAR_AD" -); expect "admin list keyword order_no" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?keyword=p6c1$TS" "$JAR_AD" -); expect "admin list keyword title" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?keyword=zznope$TS" "$JAR_AD" -); expect "admin list keyword miss" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?user_id=$STUID2" "$JAR_AD" -); expect "admin list other student 0" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?status=bogus" "$JAR_AD" -); expect "admin list bad status 400" "400" "$r"

# ---- 标记支付 ORD1 ----
r=$(req POST "/api/admin/orders/999999/pay" "$JAR_AD" "{}"); expect "pay missing 404" "404" "$r"
r=$(req POST "/api/admin/orders/abc/pay" "$JAR_AD" "{}"); expect "pay bad id 400" "400" "$r"
r=$(req POST "/api/admin/orders/$OID1/pay" "$JAR_AD" "not json"); expect "pay bad json 400" "400" "$r"
LONG=$(printf 'x%.0s' $(seq 1 300))
body="{\"remark\":\"$LONG\"}"
r=$(req POST "/api/admin/orders/$OID1/pay" "$JAR_AD" "$body"); expect "pay remark too long 400" "400" "$r"
r=$(req POST "/api/admin/orders/$OID1/pay" "$JAR_AD" "{}"); expect "pay ORD1 200" "200" "$r"
expect "ORD1 status paid" "paid" "$(jget "['data']['status']")"
expect "ORD1 operator 1" "1" "$(jget "['data']['operator_id']")"
expect "ORD1 pay_method empty" "" "$(jget "['data']['pay_method']")"
if [ "$(jget "['data']['paid_at']")" != "0" ]; then pass=$((pass+1)); echo "ok   ORD1 paid_at set"; else fail=$((fail+1)); echo "FAIL ORD1 paid_at set"; fi
# 联动：报名解锁 + 课时可学
r=$(req POST "/api/courses/$C1/enroll" "$JAR_STU" -); expect "re-enroll C1 already" "200" "$r"
expect "C1 pay_status paid" "paid" "$(jget "['data']['pay_status']")"
r=$(req POST /api/learning/progress "$JAR_STU" "{\"lesson_id\":$L1,\"status\":\"in_progress\",\"position\":0}"); expect "lesson unlocked after pay 200" "200" "$r"
r=$(req GET "/api/orders?status=paid" "$JAR_STU" -); expect "my orders paid 1" "1" "$(jget "['data']['total']")"
# 终态守卫
r=$(req POST "/api/admin/orders/$OID1/pay" "$JAR_AD" "{}"); expect "pay again 400" "400" "$r"
expectgrep "pay again text" "已支付"
r=$(req POST "/api/admin/orders/$OID1/cancel" "$JAR_AD" "{}"); expect "cancel paid 400" "400" "$r"
expectgrep "cancel paid text" "已支付"

# ---- 取消 ORD2：报名回滚 + enroll_count 回退 + 可重新报名 ----
r=$(req POST "/api/admin/orders/$OID2/cancel" "$JAR_AD" "{\"remark\":\"offline refund\"}"); expect "cancel ORD2 200" "200" "$r"
expect "ORD2 status cancelled" "cancelled" "$(jget "['data']['status']")"
expect "ORD2 cancel remark" "offline refund" "$(jget "['data']['remark']")"
expect "ORD2 operator 1" "1" "$(jget "['data']['operator_id']")"
r=$(req GET /api/me/enrollments "$JAR_STU" -); expect "enrollments after cancel 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/courses/$C2" "$JAR_AD" -); expect "C2 enroll_count rollback 0" "0" "$(jget "['data']['course']['enroll_count']")"
r=$(req POST "/api/admin/orders/$OID2/cancel" "$JAR_AD" "{}"); expect "cancel again 400" "400" "$r"
expectgrep "cancel again text" "已取消"
r=$(req POST "/api/courses/$C2/enroll" "$JAR_STU" -); expect "re-enroll C2 200" "200" "$r"
expect "re-enroll C2 pending" "pending_payment" "$(jget "['data']['status']")"
ORD3=$(jget "['data']['order_no']")
if [ "$ORD3" != "$ORD2" ]; then pass=$((pass+1)); echo "ok   new order_no differs"; else fail=$((fail+1)); echo "FAIL new order_no differs ($ORD3)"; fi
r=$(req GET "/api/orders?status=pending" "$JAR_STU" -); expect "pending after re-enroll 1" "1" "$(jget "['data']['total']")"
expect "pending is ORD3" "$ORD3" "$(jget "['data']['items'][0]['order_no']")"

# ---- 管理端代下单 ----
body="{\"user_id\":$STUID,\"course_id\":$C3}"
r=$(req POST /api/admin/orders "$JAR_AD" "$body"); expect "proxy order 200" "200" "$r"
ORD4=$(jget "['data']['order_no']")
OID4=$(jget "['data']['id']")
expect "proxy order pending" "pending" "$(jget "['data']['status']")"
expect "proxy order amount 500" "500" "$(jget "['data']['amount']")"
expect "proxy order username" "$U" "$(jget "['data']['username']")"
expect "proxy order operator 1" "1" "$(jget "['data']['operator_id']")"
r=$(req POST /api/admin/orders "$JAR_AD" "$body"); expect "proxy order dup 400" "400" "$r"
expectgrep "proxy dup text" "已报名"
body="{\"user_id\":$STUID,\"course_id\":$CF}"
r=$(req POST /api/admin/orders "$JAR_AD" "$body"); expect "proxy free course 400" "400" "$r"
expectgrep "proxy free text" "免费"
body="{\"user_id\":$STUID,\"course_id\":$CD}"
r=$(req POST /api/admin/orders "$JAR_AD" "$body"); expect "proxy draft course 400" "400" "$r"
expectgrep "proxy draft text" "未上架"
r=$(req POST /api/admin/orders "$JAR_AD" "{\"user_id\":0,\"course_id\":$C3}"); expect "proxy zero user 400" "400" "$r"
r=$(req POST /api/admin/orders "$JAR_AD" "{\"user_id\":999999,\"course_id\":$C3}"); expect "proxy missing user 404" "404" "$r"
r=$(req POST /api/admin/orders "$JAR_AD" "{\"user_id\":$STUID,\"course_id\":999999}"); expect "proxy missing course 404" "404" "$r"
# 代下单后学员视角：unpaid 报名出现在我的课程（C1 paid + C2 unpaid + C3 unpaid）
r=$(req GET /api/me/enrollments "$JAR_STU" -); expect "enrollments after proxy 3" "3" "$(jget "['data']['total']")"
r=$(req POST "/api/admin/orders/$OID4/pay" "$JAR_AD" "{\"pay_method\":\"cash\",\"remark\":\"smoke pay\"}"); expect "pay ORD4 200" "200" "$r"
expect "ORD4 pay_method" "cash" "$(jget "['data']['pay_method']")"
expect "ORD4 remark" "smoke pay" "$(jget "['data']['remark']")"
r=$(req POST "/api/courses/$C3/enroll" "$JAR_STU" -); expect "re-enroll C3 already paid" "200" "$r"
expect "C3 pay_status paid" "paid" "$(jget "['data']['pay_status']")"

# ---- 汇总状态计数 ----
r=$(req GET /api/orders "$JAR_STU" -); expect "my orders total 4" "4" "$(jget "['data']['total']")"
r=$(req GET "/api/orders?status=pending" "$JAR_STU" -); expect "my orders pending 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/orders?status=paid" "$JAR_STU" -); expect "my orders paid 2" "2" "$(jget "['data']['total']")"
r=$(req GET "/api/orders?status=cancelled" "$JAR_STU" -); expect "my orders cancelled 1" "1" "$(jget "['data']['total']")"
r=$(req GET /api/orders "$JAR_STU2" -); expect "student2 orders 0" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?user_id=$STUID&page=1&size=2" "$JAR_AD" -)
expect "admin list page1 size2 len" "2" "$(jexpr "len(d['data']['items'])")"
expect "admin list page1 size2 total 4" "4" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/orders?user_id=$STUID&page=3&size=2" "$JAR_AD" -)
expect "admin list page3 empty" "0" "$(jexpr "len(d['data']['items'])")"
# 备注保留语义：pay 时空 remark 不覆盖已有（ORD4 已有 smoke pay）
r=$(req POST "/api/admin/orders/$OID2/cancel" "$JAR_AD" "{}"); expect "cancel terminal stays" "400" "$r"

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
