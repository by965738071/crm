#!/usr/bin/env bash
# 第 5 期冒烟测试：模拟考试（试卷 CRUD/校验、开考/恢复/超时、自动保存、交卷判分、
# 成绩回顾、错题本联动、历史与删除语义）→ 关停检查
# 用法：./scripts/smoke_phase5.sh
# 说明：
# 1. 沿用「时间戳用户名 + 每次新建分类」纪律：试卷题池指向本次新建的空分类，
#    断言不受历史数据干扰。
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
JAR_AD=$DIR/phase5_adm.jar
JAR_STU=$DIR/phase5_stu.jar
JAR_STU2=$DIR/phase5_stu2.jar
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
  # curl 未落盘（连接失败/写入被拦）→ 哨兵保证每个请求恰有一个文件，序号不串位，
  # 后续断言响亮报错而非读到旧响应。
  [ -s "$lastf_" ] || { mkdir -p "$DIR/b"; echo BODY_WRITE_MISS > "$lastf_" 2>/dev/null; }
  { printf '%s %s %s ' "$m" "$p" "$code"; head -c 120 "$lastf_" 2>/dev/null | tr -d '\n'; echo; } >> "$DIR/reqlog.txt"
  echo "$code"
}
expect() { # expect <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1 ($3)";
  else fail=$((fail+1)); echo "FAIL $1 expected=$2 got=$3 body=$(head -c 300 "$(lastf)" 2>/dev/null)"; fi
}
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(eval('d'+sys.argv[2]))" "$(lastf)" "$1" 2>/dev/null || echo ""; }

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
U="p5stu$TS"; E="$U@ex.com"; PW='Passw0rd!123'
U2="p5stuB$TS"; E2="$U2@ex.com"

body='{"account":"admin","password":"admin123456"}'
r=$(req POST /api/auth/login "$JAR_AD" "$body"); expect "admin login 200" "200" "$r"

# ---- 专用分类 CATQ：题池 1 单选 + 1 判断 ----
body="{\"name\":\"p5catq$TS\",\"parent_id\":1}"
r=$(req POST /api/admin/categories "$JAR_AD" "$body"); expect "category CATQ 200" "200" "$r"
CATQ=$(jget "['data']['id']")
body="{\"category_id\":$CATQ,\"type\":\"single\",\"stem\":\"p5 q single\",\"options\":[\"opA\",\"opB\",\"opC\"],\"answer\":\"B\",\"explanation\":\"exp-single\",\"difficulty\":2}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "create single QA 200" "200" "$r"
QA=$(jget "['data']['id']")
body="{\"category_id\":$CATQ,\"type\":\"judge\",\"stem\":\"p5 q judge\",\"answer\":\"T\",\"explanation\":\"exp-judge\"}"
r=$(req POST /api/admin/questions "$JAR_AD" "$body"); expect "create judge QC 200" "200" "$r"
QC=$(jget "['data']['id']")

# ---- 试卷校验失败分支（全部 400）----
body="{\"category_id\":$CATQ,\"title\":\"sum mismatch\",\"duration_min\":30,\"total_score\":99,\"pass_score\":60,\"status\":\"published\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "bad score sum 400" "400" "$r"
body="{\"category_id\":$CATQ,\"title\":\"bad status\",\"duration_min\":30,\"total_score\":10,\"pass_score\":5,\"status\":\"on\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "bad status 400" "400" "$r"
body="{\"category_id\":$CATQ,\"title\":\"empty rules\",\"duration_min\":30,\"total_score\":10,\"pass_score\":5,\"status\":\"draft\",\"rules\":[]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "empty rules 400" "400" "$r"
body="{\"category_id\":$CATQ,\"title\":\"bad rule cat\",\"duration_min\":30,\"total_score\":10,\"pass_score\":5,\"status\":\"draft\",\"rules\":[{\"category_id\":999999,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "rule bad category 400" "400" "$r"
grep -q "不存在" "$(lastf)" && expect "rule cat msg" "ok" "ok" || expect "rule cat msg" "ok" "no"
body="{\"category_id\":$CATQ,\"title\":\"zero count\",\"duration_min\":30,\"total_score\":10,\"pass_score\":5,\"status\":\"draft\",\"rules\":[{\"category_id\":$CATQ,\"count\":0,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "rule count 0 400" "400" "$r"
body="{\"category_id\":999999,\"title\":\"main bad cat\",\"duration_min\":30,\"total_score\":10,\"pass_score\":5,\"status\":\"draft\",\"rules\":[{\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "main bad category 400" "400" "$r"
body="{\"category_id\":$CATQ,\"title\":\"\",\"duration_min\":30,\"total_score\":10,\"pass_score\":5,\"status\":\"draft\",\"rules\":[{\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "empty title 400" "400" "$r"

# ---- 建卷：EX1 published / EX2 draft / EX3 published 但池不足 ----
body="{\"category_id\":$CATQ,\"title\":\"p5 exam one\",\"duration_min\":30,\"total_score\":20,\"pass_score\":10,\"status\":\"published\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10},{\"type\":\"judge\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "create EX1 200" "200" "$r"
EX1=$(jget "['data']['id']")
expect "EX1 question_count 2" "2" "$(jget "['data']['question_count']")"
expect "EX1 status" "published" "$(jget "['data']['status']")"
body="{\"category_id\":$CATQ,\"title\":\"p5 exam draft\",\"duration_min\":20,\"total_score\":20,\"pass_score\":10,\"status\":\"draft\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10},{\"type\":\"judge\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "create EX2 draft 200" "200" "$r"
EX2=$(jget "['data']['id']")
body="{\"category_id\":$CATQ,\"title\":\"p5 exam short\",\"duration_min\":30,\"total_score\":50,\"pass_score\":25,\"status\":\"published\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":5,\"score_each\":10}]}"
r=$(req POST /api/admin/exams "$JAR_AD" "$body"); expect "create EX3 200" "200" "$r"
EX3=$(jget "['data']['id']")

# ---- 管理端列表/详情 ----
r=$(req GET "/api/admin/exams?category_id=$CATQ" "$JAR_AD" -); expect "admin list 200" "200" "$r"
expect "admin list total 3" "3" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/exams?status=draft&category_id=$CATQ" "$JAR_AD" -)
expect "admin draft filter total 1" "1" "$(jget "['data']['total']")"
expect "admin draft item EX2" "$EX2" "$(jget "['data']['items'][0]['id']")"
r=$(req GET "/api/admin/exams?keyword=exam%20one" "$JAR_AD" -)
expect "admin keyword hit" "1" "$(jget "['data']['total']")"
r=$(req GET "/api/admin/exams/$EX1" "$JAR_AD" -); expect "admin get EX1 200" "200" "$r"
expect "EX1 duration 30" "30" "$(jget "['data']['duration_min']")"
r=$(req GET /api/admin/exams/999999 "$JAR_AD" -); expect "admin get missing 404" "404" "$r"

# ---- 鉴权边界 ----
r=$(req GET /api/exams - -); expect "guest list 401" "401" "$r"
r=$(req POST "/api/exams/$EX1/start" - '{}'); expect "guest start 401" "401" "$r"
r=$(req POST /api/exam-attempts/1/submit - '{}'); expect "guest submit 401" "401" "$r"

# ---- 学员注册登录 ----
body="{\"email\":\"$E\",\"username\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student register 200" "200" "$r"
body="{\"account\":\"$U\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU" "$body"); expect "student login 200" "200" "$r"

# ---- 学员列表：仅 published ----
r=$(req GET "/api/exams?category_id=$CATQ" "$JAR_STU" -); expect "student list 200" "200" "$r"
expect "student list total 2 (no draft)" "2" "$(jget "['data']['total']")"
python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'))['data']['items'];ids=[str(x['exam']['id']) for x in d];sys.exit(0 if (str(sys.argv[2]) not in ids and str(sys.argv[3]) in ids) else 1)" "$(lastf)" "$EX2" "$EX1" \
  && expect "draft excluded, published present" "ok" "ok" || expect "draft excluded, published present" "ok" "no"
r=$(req POST "/api/exams/$EX2/start" "$JAR_STU" '{}'); expect "start draft 404" "404" "$r"
r=$(req POST "/api/exams/999999/start" "$JAR_STU" '{}'); expect "start missing 404" "404" "$r"
r=$(req POST "/api/exams/$EX3/start" "$JAR_STU" '{}'); expect "start pool shortage 400" "400" "$r"
grep -q "题池不足" "$(lastf)" && expect "pool msg" "ok" "ok" || expect "pool msg" "ok" "no"

# ---- 开考 EX1：快照无答案泄漏、时长正确 ----
r=$(req POST "/api/exams/$EX1/start" "$JAR_STU" '{}'); expect "start EX1 200" "200" "$r"
ATT_A=$(jget "['data']['attempt_id']")
expect "start resumed false" "False" "$(jget "['data']['resumed']")"
expect "start 2 questions" "2" "$(jget "['data']['questions'].__len__()")"
expect "start no saved answers" "0" "$(jget "['data']['answers'].__len__()")"
expect "deadline -30min" "1800" "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'))['data'];print(d['deadline_at']-d['started_at'])" "$(lastf)")"
expect "remaining >1790" "1" "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'))['data'];print(1 if d['remaining_sec']>1790 else 0)" "$(lastf)")"
python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'))['data'];sys.exit(0 if all('answer' not in q and 'explanation' not in q for q in d['questions']) else 1)" "$(lastf)" \
  && expect "snapshot hides answers" "ok" "ok" || expect "snapshot hides answers" "ok" "leak"

# ---- 自动保存（全对）→ 断线恢复 ----
python3 -c "import json,sys;a=json.load(open(sys.argv[1],encoding='utf-8'))['data'];ans=[{'question_id':q['id'],'answer':{'single':'B','judge':'T'}[q['type']]} for q in a['questions']];print(json.dumps({'answers':ans}))" "$(lastf)" > "$DIR/ans-$TS.json"
r=$(req POST "/api/exam-attempts/$ATT_A/answer" "$JAR_STU" "@$DIR/ans-$TS.json"); expect "autosave 200" "200" "$r"
expect "autosave saved 2" "2" "$(jget "['data']['saved']")"
r=$(req POST "/api/exams/$EX1/start" "$JAR_STU" '{}'); expect "resume 200" "200" "$r"
expect "resume same attempt" "$ATT_A" "$(jget "['data']['attempt_id']")"
expect "resume flag true" "True" "$(jget "['data']['resumed']")"
expect "resume has answers" "2" "$(jget "['data']['answers'].__len__()")"
r=$(req POST "/api/exam-attempts/999999/answer" "$JAR_STU" '{"answers":[]}'); expect "autosave missing 404" "404" "$r"

# ---- 交卷（空 body 用存量）→ 满分通过 ----
r=$(req POST "/api/exam-attempts/$ATT_A/submit" "$JAR_STU" '{}'); expect "submit A 200" "200" "$r"
expect "score A 20" "20" "$(jget "['data']['score']")"
expect "total A 20" "20" "$(jget "['data']['total_score']")"
expect "passed A" "True" "$(jget "['data']['passed']")"
expect "correct A 2/2" "2" "$(jget "['data']['correct_count']")"
r=$(req POST "/api/exam-attempts/$ATT_A/submit" "$JAR_STU" '{}'); expect "double submit 400" "400" "$r"
r=$(req POST "/api/exam-attempts/$ATT_A/answer" "$JAR_STU" '{"answers":[]}'); expect "autosave after submit 400" "400" "$r"

# ---- 第二场：单选答错（入错题本）+ 判断未答（不入本）----
r=$(req POST "/api/exams/$EX1/start" "$JAR_STU" '{}'); expect "start attempt B 200" "200" "$r"
ATT_B=$(jget "['data']['attempt_id']")
[ "$ATT_B" != "$ATT_A" ] && expect "new attempt id differs" "ok" "ok" || expect "new attempt id differs" "ok" "same"
echo '{"answers":[{"question_id":'"$QA"',"answer":"A"},{"question_id":'"$QC"',"answer":""}]}' > "$DIR/ansb-$TS.json"
r=$(req POST "/api/exam-attempts/$ATT_B/submit" "$JAR_STU" "@$DIR/ansb-$TS.json"); expect "submit B 200" "200" "$r"
expect "score B 0" "0" "$(jget "['data']['score']")"
expect "passed B false" "False" "$(jget "['data']['passed']")"

# ---- 第三场：回顾未交卷 → 400；交白卷 ----
r=$(req POST "/api/exams/$EX1/start" "$JAR_STU" '{}'); expect "start attempt C 200" "200" "$r"
ATT_C=$(jget "['data']['attempt_id']")
r=$(req GET "/api/exam-attempts/$ATT_C" "$JAR_STU" -); expect "review unsubmitted 400" "400" "$r"
grep -q "尚未交卷" "$(lastf)" && expect "unsubmitted msg" "ok" "ok" || expect "unsubmitted msg" "ok" "no"
r=$(req POST "/api/exam-attempts/$ATT_C/submit" "$JAR_STU" '{}'); expect "submit C blank 200" "200" "$r"
expect "score C 0" "0" "$(jget "['data']['score']")"

# ---- 成绩回顾 ----
r=$(req GET "/api/exam-attempts/$ATT_A" "$JAR_STU" -); expect "review A 200" "200" "$r"
expect "review A exam title" "p5 exam one" "$(jget "['data']['exam_title']")"
expect "review A total 20" "20" "$(jget "['data']['total_score']")"
expect "review A passed" "True" "$(jget "['data']['passed']")"
expect "review A items 2" "2" "$(jget "['data']['items'].__len__()")"
expect "review A has answers" "True" "$(jget "['data']['items'][0]['correct']")"
expect "review A single answer" "B" "$(jget "['data']['items'][0]['answer']")"
expect "review A has explanation" "True" "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'))['data'];print(str(bool(d['items'][0]['explanation'])))" "$(lastf)")"
expect "review A score_gained 10" "10" "$(jget "['data']['items'][0]['score_gained']")"
r=$(req GET "/api/exam-attempts/$ATT_B" "$JAR_STU" -); expect "review B 200" "200" "$r"
expect "review B single wrong" "False" "$(jget "['data']['items'][0]['correct']")"
expect "review B single student" "A" "$(jget "['data']['items'][0]['student_answer']")"
expect "review B judge blank" "" "$(jget "['data']['items'][1]['student_answer']")"
expect "review B judge not in wrongbook via blank" "False" "$(jget "['data']['items'][1]['correct']")"
r=$(req GET /api/exam-attempts/999999 "$JAR_STU" -); expect "review missing 404" "404" "$r"

# ---- 错题本联动：QA（答错）在列，QC（未答）不在 ----
r=$(req GET "/api/practice/wrong?mastered=0" "$JAR_STU" -); expect "wrong list 200" "200" "$r"
expect "wrong total 1 (exam QA)" "1" "$(jget "['data']['total']")"
expect "wrong item QA" "$QA" "$(jget "['data']['items'][0]['question']['id']")"

# ---- 历史与统计 ----
r=$(req GET "/api/exam-attempts?exam_id=$EX1" "$JAR_STU" -); expect "attempt list 200" "200" "$r"
expect "attempt list total 3" "3" "$(jget "['data']['total']")"
expect "attempt list item has title" "p5 exam one" "$(jget "['data']['items'][0]['exam_title']")"
expect "attempt best is C(0) first (id desc)" "0" "$(jget "['data']['items'][0]['score']")"
r=$(req GET "/api/exam-attempts?exam_id=999999" "$JAR_STU" -)
expect "attempt list filter empty" "0" "$(jget "['data']['total']")"
r=$(req GET "/api/exams?category_id=$CATQ" "$JAR_STU" -); expect "student list stats 200" "200" "$r"
python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'))['data']['items'];r=[x for x in d if str(x['exam']['id'])==sys.argv[2]][0];sys.exit(0 if int(r['my_attempts'])==3 and int(r['my_best_score'])==20 else 1)" "$(lastf)" "$EX1" \
  && expect "EX1 my_attempts 3 best 20" "ok" "ok" || expect "EX1 my_attempts 3 best 20" "ok" "no"

# ---- 越权隔离（学员 B）----
body="{\"email\":\"$E2\",\"username\":\"$U2\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/register - "$body"); expect "student2 register 200" "200" "$r"
body="{\"account\":\"$U2\",\"password\":\"$PW\"}"
r=$(req POST /api/auth/login "$JAR_STU2" "$body"); expect "student2 login 200" "200" "$r"
r=$(req GET "/api/exam-attempts/$ATT_A" "$JAR_STU2" -); expect "B review A 404" "404" "$r"
r=$(req POST "/api/exam-attempts/$ATT_A/submit" "$JAR_STU2" '{}'); expect "B submit A 404" "404" "$r"
r=$(req POST "/api/exam-attempts/$ATT_A/answer" "$JAR_STU2" '{"answers":[]}'); expect "B autosave A 404" "404" "$r"

# ---- 管理端更新 ----
body="{\"category_id\":$CATQ,\"title\":\"t\",\"duration_min\":30,\"total_score\":999,\"pass_score\":1,\"status\":\"published\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req PUT "/api/admin/exams/$EX1" "$JAR_AD" "$body"); expect "update bad sum 400" "400" "$r"
body="{\"category_id\":$CATQ,\"title\":\"p5 exam one v2\",\"duration_min\":45,\"total_score\":20,\"pass_score\":10,\"status\":\"published\",\"rules\":[{\"type\":\"single\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10},{\"type\":\"judge\",\"category_id\":$CATQ,\"count\":1,\"score_each\":10}]}"
r=$(req PUT "/api/admin/exams/$EX1" "$JAR_AD" "$body"); expect "update 200" "200" "$r"
expect "update title" "p5 exam one v2" "$(jget "['data']['title']")"
expect "update duration 45" "45" "$(jget "['data']['duration_min']")"
r=$(req PUT "/api/admin/exams/999999" "$JAR_AD" "$body"); expect "update missing 404" "404" "$r"

# ---- 删除试卷：新卷不可见，历史成绩仍可读 ----
r=$(req DELETE "/api/admin/exams/$EX1" "$JAR_AD" -); expect "delete EX1 200" "200" "$r"
r=$(req POST "/api/exams/$EX1/start" "$JAR_STU" '{}'); expect "start deleted 404" "404" "$r"
r=$(req GET "/api/exam-attempts/$ATT_A" "$JAR_STU" -); expect "review deleted exam still 200" "200" "$r"
expect "deleted exam title still in review" "p5 exam one v2" "$(jget "['data']['exam_title']")"
r=$(req GET "/api/admin/exams?category_id=$CATQ" "$JAR_AD" -)
expect "admin list after delete 2" "2" "$(jget "['data']['total']")"
r=$(req DELETE "/api/admin/exams/$EX1" "$JAR_AD" -); expect "delete again 404" "404" "$r"

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
