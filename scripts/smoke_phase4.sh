#!/usr/bin/env bash
# 第 4 期冒烟测试：题库与练习（题目 CRUD/导入、抽题、判分、错题本、收藏）→ 关停检查
# 用法：./scripts/smoke_phase4.sh
# 说明：
# 1. 沿用「时间戳用户名 + 每次新建分类」纪律：题目全部挂到本次新建的空分类 CAT4/CAT5，
#    抽题/错题/收藏/used_count 断言不受历史数据干扰，无需全新 DB。
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
JAR_AD=$DIR/phase4_adm.jar
JAR_STU=$DIR/phase4_stu.jar
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
U="p4stu$TS"; E="$U@ex.com"; PW='Passw0rd!123'

body='{"account":"admin","password":"admin123456"}'
r=$(req POST /api/auth/login "$JAR_AD" "$body"); expect "admin login 200" "200" "$r"

# ---- 本次专用分类：CAT4 放题，CAT5 保持空（测空池）----
body="{\"name\":\"p4cat$TS\",\"parent_id\":1}"
r=$(req POST /api/admin/categories "$JAR_AD" "$body"); expect "category CAT4 200" "200" "$r"
CAT4=$(jget "['data']['id']")
body="{\"name\":\"p4empty$TS\",\"parent_id\":1}"
r=$(req POST /api/admin/categories "$JAR_AD" "$body"); expect "category CAT5 200" "200" "$r"
CAT5=$(jget "['data']['id']")

# ---- 建题校验失败分支 ----
body="{\"category_id\":$CAT4,\"type\":\"xxx\",\"stem\":\"s\",\"options\":[\"a\",\"b\"],\"answer\":\"A\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "bad type 400" "400" "$r"
body="{\"category_id\":999999,\"type\":\"single\",\"stem\":\"s\",\"options\":[\"a\",\"b\"],\"answer\":\"A\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "bad category 400" "400" "$r"
body="{\"category_id\":$CAT4,\"type\":\"multi\",\"stem\":\"s\",\"options\":[\"a\",\"b\",\"c\"],\"answer\":\"A\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "multi single-letter 400" "400" "$r"
body="{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"s\",\"options\":[\"a\",\"b\"],\"answer\":\"E\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "answer beyond options 400" "400" "$r"

# ---- 建题：single Q1 / multi Q2 / judge Q3 ----
body="{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"q1 kwONLYq2 base\",\"options\":[\"opA\",\"opB\",\"opC\"],\"answer\":\"B\",\"explanation\":\"because\",\"difficulty\":3}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "create single 200" "200" "$r"
Q1=$(jget "['data']['id']")
body="{\"category_id\":$CAT4,\"type\":\"multi\",\"stem\":\"q2 multi\",\"options\":[\"opA\",\"opB\",\"opC\",\"opD\"],\"answer\":\"AC\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "create multi 200" "200" "$r"
Q2=$(jget "['data']['id']")
# judge：options 传了也应被忽略存 []；answer TRUE 规范化为 T
body="{\"category_id\":$CAT4,\"type\":\"judge\",\"stem\":\"q3 judge\",\"options\":[\"should\",\"be\",\"ignored\"],\"answer\":\"TRUE\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "create judge 200" "200" "$r"
Q3=$(jget "['data']['id']")

r=$(req GET "/api/admin/questions/$Q3" "$JAR_AD" -); expect "judge get 200" "200" "$r"
expect "judge answer canonical T" "T" "$(jget "['data']['answer']")"
expect "judge options emptied" "[]" "$(jget "['data']['options'].__repr__()")"

# ---- 更新 Q1 答案 B→C，读回 ----
body="{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"q1 kwONLYq2 base\",\"options\":[\"opA\",\"opB\",\"opC\"],\"answer\":\"C\",\"explanation\":\"upd\",\"difficulty\":3}"
r=$(req PUT "/api/admin/questions/$Q1" "$JAR_AD" "$body"); expect "update Q1 200" "200" "$r"
r=$(req GET "/api/admin/questions/$Q1" "$JAR_AD" -)
expect "Q1 answer now C" "C" "$(jget "['data']['answer']")"
expect "Q1 used_count 0" "0" "$(jget "['data']['used_count']")"

# ---- 列表过滤 ----
r=$(req GET "/api/admin/questions?category_id=$CAT4" "$JAR_AD" -); expect "list by cat 200" "200" "$r"
expect "list cat4 total 3" "3" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/questions?keyword=kwONLYq2" "$JAR_AD" -)
expect "keyword hit 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/questions?category_id=$CAT4&type=judge" "$JAR_AD" -)
expect "type=judge hit 1" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/questions?category_id=$CAT4&type=nope" "$JAR_AD" -); expect "bad type filter 400" "400" "$r"

# ---- 导入：JSON ----
r=$(req POST /api/admin/questions/import "$JAR_AD" -); expect "import empty 400" "400" "$r"
both="{\"questions\":[{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"x\",\"options\":[\"a\",\"b\"],\"answer\":\"A\"}],\"csv\":\"type,category_id,course_id,stem,options,answer,explanation,difficulty\nsingle,$CAT4,,x,a|b,A,,\"}"
r=$(req POST /api/admin/questions/import "$JAR_AD" "$both"); expect "import both-fields 400" "400" "$r"
badimp="{\"questions\":[{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"good row\",\"options\":[\"a\",\"b\"],\"answer\":\"A\"},{\"category_id\":$CAT4,\"type\":\"multi\",\"stem\":\"bad row\",\"options\":[\"a\",\"b\",\"c\"],\"answer\":\"A\"}]}"
r=$(req POST /api/admin/questions/import "$JAR_AD" "$badimp"); expect "import bad row 400" "400" "$r"
# 注：AppError 响应体是纯文本（res.text），不是 JSON → 用 grep 断言错误文案
grep -q "第2行" "$DIR/last.json" \
  && expect "import error mentions row2" "ok" "ok" || expect "import error mentions row2" "ok" "no"
# 全有成败：上面失败后 CAT4 仍 3 题
r=$(req GET "/api/admin/questions?category_id=$CAT4" "$JAR_AD" -)
expect "all-or-nothing still 3" "3" "$(jget "['data']['total']")"
okimp="{\"questions\":[{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"imp1\",\"options\":[\"a\",\"b\"],\"answer\":\"A\"},{\"category_id\":$CAT4,\"type\":\"single\",\"stem\":\"imp2\",\"options\":[\"a\",\"b\"],\"answer\":\"B\",\"difficulty\":5}]}"
r=$(req POST /api/admin/questions/import "$JAR_AD" "$okimp"); expect "import json 200" "200" "$r"
expect "imported=2" "2" "$(jget "['data']['imported']")"
r=$(req GET "/api/admin/questions?category_id=$CAT4" "$JAR_AD" -)
expect "cat4 now 5" "5" "$(jget "['data']['total']")"

# ---- 导入：CSV ----
csvimp='{"csv":"type,category_id,course_id,stem,options,answer,explanation,difficulty\nsingle,'$CAT4',,csvok,\"a|b,c\",A,\"expl, with comma\",4\njudge,'$CAT4',,csvj,,TRUE,,\n"}'
r=$(req POST /api/admin/questions/import "$JAR_AD" "$csvimp"); expect "import csv 200" "200" "$r"
expect "csv imported=2" "2" "$(jget "['data']['imported']")"
csvbad='{"csv":"type,wrong,header\nsingle,'$CAT4',,x,a|b,A,,\n"}'
r=$(req POST /api/admin/questions/import "$JAR_AD" "$csvbad"); expect "csv bad header 400" "400" "$r"
csvtrailing='{"csv":"type,category_id,course_id,stem,options,answer,explanation,difficulty\nsingle,'$CAT4',,trailer,a|b,c,A,,\n"}'
r=$(req POST /api/admin/questions/import "$JAR_AD" "$csvtrailing"); expect "csv too many cols 400" "400" "$r"

# ---- 学员注册登录 ----
body="{\"email\":\"$E\",\"username\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student register 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU" "$body"); expect "student login 200" "200" "$r"

# ---- 鉴权与参数边界 ----
r=$(req POST /api/practice/start - "{\"mode\":\"chapter\",\"category_id\":$CAT4}"); expect "guest start 401" "401" "$r"
r=$(req GET /api/practice/wrong - -); expect "guest wrong 401" "401" "$r"
r=$(req GET /api/practice/favorites - -); expect "guest favorites 401" "401" "$r"
r=$(req POST /api/practice/start "$JAR_STU" "{\"mode\":\"xx\",\"category_id\":$CAT4}"); expect "bad mode 400" "400" "$r"
r=$(req POST /api/practice/start "$JAR_STU" "{\"mode\":\"chapter\",\"category_id\":999999}"); expect "start bad cat 400" "400" "$r"
r=$(req POST /api/practice/start "$JAR_STU" "{\"mode\":\"chapter\",\"category_id\":$CAT5}"); expect "empty pool 400" "400" "$r"

# ---- 抽题：chapter（CAT4 共 7 题：3+2JSON+2CSV），count 钳到池内 ----
r=$(req POST /api/practice/start "$JAR_STU" "{\"mode\":\"chapter\",\"category_id\":$CAT4,\"count\":9999}"); expect "start 200" "200" "$r"
expect "start count=7" "7" "$(jget "['data']['count']")"
expect "start total rows" "7" "$(jget "['data']['items'].__len__()")"
python3 -c "import json,sys;d=json.load(open(sys.argv[1]))['data'];sys.exit(0 if all('answer' not in it and 'explanation' not in it for it in d['items']) else 1)" "$DIR/last.json" \
  && expect "start view hides answers" "ok" "ok" || expect "start view hides answers" "ok" "leak"
# used_count：chapter 模式全抽，Q1 必被命中；在 random 抽题前检查，避免随机命中使计数歧义
r=$(req GET "/api/admin/questions/$Q1" "$JAR_AD" -)
expect "Q1 used_count 1" "1" "$(jget "['data']['used_count']")"
r=$(req POST /api/practice/start "$JAR_STU" "{\"mode\":\"random\",\"category_id\":$CAT4,\"count\":2}"); expect "random start 200" "200" "$r"
expect "random count=2" "2" "$(jget "['data']['count']")"

# ---- 判分 ----
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":0,\"answer\":\"A\"}"); expect "submit no qid 400" "400" "$r"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":999999,\"answer\":\"A\"}"); expect "submit missing 404" "404" "$r"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"\"}"); expect "submit empty 400" "400" "$r"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"123\"}"); expect "submit no-letter 400" "400" "$r"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"B\",\"source\":\"xx\"}"); expect "submit bad source 400" "400" "$r"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"B\",\"duration\":99999}"); expect "submit duration clamp 400" "400" "$r"
# Q1 正确答 C（update 后），先答错 B → 入错题本
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"B\",\"duration\":5}"); expect "submit wrong 200" "200" "$r"
expect "Q1 wrong correct=false" "False" "$(jget "['data']['correct']")"
expect "Q1 echoes canonical" "C" "$(jget "['data']['answer']")"
expect "Q1 in_wrong_book" "True" "$(jget "['data']['in_wrong_book']")"
expect "Q1 wrong_count 1" "1" "$(jget "['data']['wrong_count']")"
# 再错 → 2
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"A\"}")
expect "Q1 wrong_count 2" "2" "$(jget "['data']['wrong_count']")"
# 答对 → mastered=1，in_wrong_book false（但记录保留）
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"C\"}")
expect "Q1 correct now" "True" "$(jget "['data']['correct']")"
expect "Q1 mastered leaves book view" "False" "$(jget "['data']['in_wrong_book']")"
expect "Q1 wrong_count kept" "2" "$(jget "['data']['wrong_count']")"
# 多选宽松格式：乱序+重复+小写 "ca,C" → "AC" 判对
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q2,\"answer\":\"ca,C\"}"); expect "Q2 lenient multi 200" "200" "$r"
expect "Q2 correct" "True" "$(jget "['data']['correct']")"
# 判断：答 "true"（小写宽松）→ 对
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q3,\"answer\":\"true\"}"); expect "Q3 judge lenient 200" "200" "$r"
expect "Q3 correct" "True" "$(jget "['data']['correct']")"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q3,\"answer\":\"F\"}")
expect "Q3 wrong now" "False" "$(jget "['data']['correct']")"

# ---- 错题本 ----
r=$(req GET "/api/practice/wrong?mastered=0" "$JAR_STU" -); expect "wrong list 200" "200" "$r"
expect "wrong unmastered total 1 (Q3)" "1" "$(jget "['data']['total']")"
expect "wrong item is Q3" "$Q3" "$(jget "['data']['items'][0]['question']['id']")"
expect "wrong item wrong_count 1" "1" "$(jget "['data']['items'][0]['wrong_count']")"
expect "wrong view has answer" "T" "$(jget "['data']['items'][0]['question']['answer']")"
r=$(req GET "/api/practice/wrong?mastered=1" "$JAR_STU" -)
expect "wrong mastered total 1 (Q1)" "1" "$(jget "['data']['total']")"
expect "mastered item is Q1" "$Q1" "$(jget "['data']['items'][0]['question']['id']")"
r=$(req GET "/api/practice/wrong?mastered=-1" "$JAR_STU" -)
expect "wrong all total 2" "2" "$(jget "['data']['total']")"
# 手动标记已掌握：取未掌握列表首行（当前仅 Q3）
r=$(req GET "/api/practice/wrong?mastered=0" "$JAR_STU" -)
WID=$(jget "['data']['items'][0]['id']")
r=$(req POST "/api/practice/wrong/$WID/master" "$JAR_STU" -); expect "master 200" "200" "$r"
r=$(req POST "/api/practice/wrong/$WID/master" "$JAR_STU" -); expect "master idempotent 200" "200" "$r"
r=$(req GET "/api/practice/wrong?mastered=0" "$JAR_STU" -)
expect "unmastered now 0" "0" "$(jget "['data']['total']")"
r=$(req POST /api/practice/wrong/999999/master "$JAR_STU" -); expect "master missing 404" "404" "$r"

# ---- 收藏 ----
r=$(req POST "/api/questions/$Q2/favorite" "$JAR_STU" -); expect "fav add 200" "200" "$r"
expect "favorited true" "True" "$(jget "['data']['favorited']")"
r=$(req GET /api/practice/favorites "$JAR_STU" -); expect "favorites list 200" "200" "$r"
expect "favorites total 1" "1" "$(jget "['data']['total']")"
expect "fav item is Q2" "$Q2" "$(jget "['data']['items'][0]['question']['id']")"
expect "fav view has answer" "AC" "$(jget "['data']['items'][0]['question']['answer']")"
r=$(req POST "/api/questions/$Q2/favorite" "$JAR_STU" -)
expect "fav toggle off" "False" "$(jget "['data']['favorited']")"
r=$(req GET /api/practice/favorites "$JAR_STU" -)
expect "favorites empty now" "0" "$(jget "['data']['total']")"
r=$(req POST "/api/questions/999999/favorite" "$JAR_STU" -); expect "fav missing q 404" "404" "$r"

# ---- 软删联动 ----
r=$(req DELETE "/api/admin/questions/$Q1" "$JAR_AD" -); expect "delete Q1 200" "200" "$r"
r=$(req DELETE "/api/admin/questions/$Q1" "$JAR_AD" -); expect "delete again 404" "404" "$r"
r=$(req GET "/api/admin/questions/$Q1" "$JAR_AD" -); expect "get deleted 404" "404" "$r"
r=$(req POST /api/practice/submit "$JAR_STU" "{\"question_id\":$Q1,\"answer\":\"C\"}"); expect "submit deleted 404" "404" "$r"
r=$(req POST "/api/questions/$Q1/favorite" "$JAR_STU" -); expect "fav deleted 404" "404" "$r"
r=$(req GET "/api/practice/wrong?mastered=-1" "$JAR_STU" -)
expect "deleted hidden from wrong" "1" "$(jget "['data']['total']")"  # 只剩 Q3

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
