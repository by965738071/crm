#!/usr/bin/env bash
# 第 1 期冒烟测试：启动服务 → 认证/用户管理主流程 → 关停检查
# 用法：./scripts/smoke_phase1.sh
# 注意：macOS bash 3.2 在「双引号参数里嵌套 $(...) 且内含 \" 转义」时会破坏参数
#       （实测 bug），所有带 JSON 体的请求必须先赋值到变量再断言。
set -u
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.smoke
mkdir -p "$DIR"
LOG="$DIR/server.log"

pass=0; fail=0
expect() { # expect <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1 ($3)";
  else fail=$((fail+1)); echo "FAIL $1 expected=$2 got=$3 body=$(head -c 300 "$DIR/last.json" 2>/dev/null)"; fi
}
req() { # req <method> <path> <jar|- > <json|- > → stdout=状态码，body → $DIR/last.json
  local m=$1 p=$2 jar=$3 data=$4 args=(-s -o "$DIR/last.json" -w "%{http_code}")
  [ "$jar" != "-" ] && args+=(-b "$jar" -c "$jar")
  [ "$data" != "-" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  curl "${args[@]}" -X "$m" "$BASE$p"
}
# jget <python 下标表达式>：从 $DIR/last.json 取值，失败输出空
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval('d'+sys.argv[2]))" "$DIR/last.json" "$1" 2>/dev/null || echo ""; }

TS=$(date +%s)
E="stu$TS@ex.com"; U="stu$TS"; PW='Passw0rd!123'; NEWPW='Passw0rd!456'
JAR_STU="$DIR/stu.jar"; JAR_ADM="$DIR/adm.jar"; JAR_X="$DIR/x.jar"
rm -f "$JAR_STU" "$JAR_ADM" "$JAR_X"

LEFT=$(pgrep -x crm || true)
if [ -n "$LEFT" ]; then echo "已有 crm 进程在运行（$LEFT），先停掉它"; exit 1; fi

"$BIN" > "$LOG" 2>&1 &
P=$!
# 等待就绪（最长 30s）
for _ in $(seq 1 60); do
  curl -sf "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
r=$(req GET /api/health - -); expect "health 200" "200" "$r"

# ---- 注册 / 登录 / me / 改资料 ----
body="{\"email\":\"$E\",\"username\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "register 200" "200" "$r"
body="{\"email\":\"$E\",\"username\":\"other$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "dup register 409" "409" "$r"
r=$(req POST /api/auth/register - '{oops'); expect "bad json 400" "400" "$r"

body="{\"account\":\"$E\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU" "$body"); expect "login 200" "200" "$r"
STUID=$(jget "['data']['id']")
r=$(req GET /api/auth/me "$JAR_STU" -); expect "me 200" "200" "$r"
r=$(req PUT /api/auth/profile "$JAR_STU" '{"nickname":"冒烟昵称"}'); expect "profile 200" "200" "$r"
expect "nickname updated" "冒烟昵称" "$(jget "['data']['nickname']")"
r=$(req GET /api/auth/me - -); expect "me no cookie 401" "401" "$r"
r=$(req GET /api/admin/users "$JAR_STU" -); expect "student hits admin 403" "403" "$r"

# ---- 超管登录 / 用户管理 ----
r=$(req POST /api/auth/login "$JAR_ADM" '{"account":"admin","password":"admin123456"}')
expect "admin login 200" "200" "$r"
ADMID=$(jget "['data']['id']")
r=$(req GET "/api/admin/users?page=1&size=10&keyword=stu$TS" "$JAR_ADM" -); expect "admin users 200" "200" "$r"
expect "keyword hit 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/users/$STUID" "$JAR_ADM" -); expect "admin user get 200" "200" "$r"
r=$(req GET "/api/admin/users/999999" "$JAR_ADM" -); expect "get missing 404" "404" "$r"
r=$(req PUT "/api/admin/users/$ADMID/status" "$JAR_ADM" '{"status":"disabled"}'); expect "self disable 400" "400" "$r"
r=$(req PUT "/api/admin/users/$STUID/status" "$JAR_ADM" '{"status":"nope"}'); expect "bad status 400" "400" "$r"

# ---- 改密 + 会话轮换 ----
body="{\"old_password\":\"$PW\",\"new_password\":\"$NEWPW\"}"
r=$(req PUT /api/auth/password "$JAR_STU" "$body"); expect "change pwd 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$NEWPW\"}"
r=$(req POST /api/auth/login "$JAR_X" "$body"); expect "login new pwd 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login - "$body"); expect "login old pwd 401" "401" "$r"
r=$(req GET /api/auth/me "$JAR_X" -); expect "new session me 200" "200" "$r"

# ---- 禁用 ----
r=$(req PUT "/api/admin/users/$STUID/status" "$JAR_ADM" '{"status":"disabled"}'); expect "disable student 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$NEWPW\"}"
r=$(req POST /api/auth/login - "$body"); expect "login disabled 403" "403" "$r"
body="{\"password\":\"$NEWPW\"}"
r=$(req POST "/api/admin/users/$STUID/reset-password" "$JAR_ADM" "$body"); expect "reset pwd 200" "200" "$r"

# ---- 防暴力：5 次失败后锁 ----
body="{\"account\":\"nobody$TS\",\"password\":\"wrongpass1\"}"
for i in 1 2 3 4 5; do
  r=$(req POST /api/auth/login - "$body")
  expect "bad login #$i 401" "401" "$r"
done
r=$(req POST /api/auth/login - "$body"); expect "6th attempt 429" "429" "$r"

# ---- 角色 ----
r=$(req PUT "/api/admin/users/$STUID/role" "$JAR_ADM" '{"role":"admin"}'); expect "put role 200" "200" "$r"
r=$(req PUT "/api/admin/users/$ADMID/role" "$JAR_ADM" '{"role":"student"}'); expect "self role 400" "400" "$r"

# ---- 登出 ----
r=$(req POST /api/auth/logout "$JAR_ADM" -); expect "logout 200" "200" "$r"
r=$(req GET /api/auth/me "$JAR_ADM" -); expect "me after logout 401" "401" "$r"
r=$(req POST /api/auth/logout "$JAR_ADM" -); expect "logout idempotent 200" "200" "$r"

# ---- 关停：退出码 + 泄漏检查 ----
kill $P
wait $P 2>/dev/null
rc=$?
expect "server exit 0 after SIGTERM" "0" "$rc"
if grep -qiE "leak|panic" "$LOG"; then echo "FAIL shutdown 日志有泄漏/panic："; grep -inE "leak|panic" "$LOG"; fail=$((fail+1)); else pass=$((pass+1)); echo "ok   shutdown 日志干净"; fi

# ---- 端口占用路径（再起一个 → 非零退出且无泄漏）----
"$BIN" > "$LOG" 2>&1 &
Q=$!
sleep 1
"$BIN" > "$DIR/second.log" 2>&1
rc2=$?
if [ $rc2 -ne 0 ]; then pass=$((pass+1)); echo "ok   第二实例非零退出 ($rc2)"; else fail=$((fail+1)); echo "FAIL 第二实例竟然成功"; fi
if grep -qi "AddressInUse" "$DIR/second.log"; then pass=$((pass+1)); echo "ok   AddressInUse 报错"; else fail=$((fail+1)); echo "FAIL 无 AddressInUse：$(cat "$DIR/second.log")"; fi
if grep -qiE "leak|panic" "$DIR/second.log"; then echo "FAIL 第二实例泄漏：$(cat "$DIR/second.log")"; fail=$((fail+1)); else pass=$((pass+1)); echo "ok   第二实例无泄漏"; fi
kill $Q 2>/dev/null
wait $Q 2>/dev/null

echo "---- server.log ----"
cat "$LOG"
echo "===================="
echo "PASS=$pass FAIL=$fail"
[ $fail -eq 0 ]
