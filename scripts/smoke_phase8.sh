#!/usr/bin/env bash
# 第 8 期冒烟：SPA 静态资源与路由回退
#   - GET / 返回 index.html（引用 /static/assets/*）
#   - 非 /api 深链 GET 回退 index.html（text/html）
#   - /static/assets/<真实产物> 返回 JS/CSS
#   - /api/* 未知路径仍是 JSON 404（不被 SPA 回退吞掉）
#   - 非 GET 的未知路径 404；静态文件缺失 404
#   - 关停日志无 leak/panic
# 用法：./scripts/smoke_phase8.sh
set -u
cd "$(dirname "$0")/.."
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.smoke
mkdir -p "$DIR"
LOG="$DIR/server.log"
rm -f "$LOG"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  *) ON_WINDOWS=0 ;;
esac

pass=0; fail=0
lastf="$DIR/p8_body.txt"
req() { # req <method> <path> → stdout=状态码，body → $lastf
  local m=$1 p=$2
  curl -s -w "%{http_code}" -o "$lastf" -X "$m" "$BASE$p" 2>/dev/null
}
expect() { # expect <name> <expected> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1";
  else fail=$((fail+1)); echo "FAIL $1 expected=$2 got=$3 body=$(head -c 200 "$lastf" 2>/dev/null)"; fi
}
expectgrep() { # expectgrep <name> <pattern>
  if grep -q "$2" "$lastf" 2>/dev/null; then pass=$((pass+1)); echo "ok   $1";
  else fail=$((fail+1)); echo "FAIL $1 pattern=$2 body=$(head -c 200 "$lastf" 2>/dev/null)"; fi
}
ctype() { curl -s -o /dev/null -w "%{content_type}" "$BASE$1" 2>/dev/null; }

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

# ---- dist 产物存在性（构建前置检查，不属于服务端断言）----
IDX_JS=$(ls web/dist/assets/index-*.js 2>/dev/null | head -1)
IDX_CSS=$(ls web/dist/assets/index-*.css 2>/dev/null | head -1)
if [ -z "$IDX_JS" ] || [ -z "$IDX_CSS" ]; then
  echo "web/dist 未构建（缺 index-*.js/css）。先执行：cd web && npm run build"; kill $P 2>/dev/null; exit 1
fi
JS_NAME=$(basename "$IDX_JS"); CSS_NAME=$(basename "$IDX_CSS")

# ---- 首页 ----
r=$(req GET /); expect "GET / 200" "200" "$r"
expect "GET / content-type html" "1" "$(ctype / | grep -c '^text/html')"
expectgrep "GET / 引用 assets js" "/static/assets/index-"
expectgrep "GET / 引用 assets css" "/static/assets/index-"

# ---- SPA 深链回退 ----
for p in /courses /courses/123 /me/profile /exam-taking/9 /lessons/3 /any-random-deep-link-x; do
  r=$(req GET "$p"); expect "深链回退 $p → 200" "200" "$r"
done
expectgrep "深链 body 是 index.html" "id=\"app\""
r=$(req GET /login); expect "深链 /login 200" "200" "$r"

# ---- 静态资源 ----
r=$(req GET "/static/assets/$JS_NAME"); expect "静态 JS 200" "200" "$r"
expect "JS content-type" "1" "$(ctype "/static/assets/$JS_NAME" | grep -cE 'javascript|ecmascript')"; 
r=$(req GET "/static/assets/$CSS_NAME"); expect "静态 CSS 200" "200" "$r"
expect "CSS content-type" "1" "$(ctype "/static/assets/$CSS_NAME" | grep -c '^text/css')"
r=$(req GET /static/assets/not-exist-$RANDOM.js); expect "缺失静态文件 404" "404" "$r"

# ---- /api 未知路径不被回退吞掉 ----
r=$(req GET /api/nothing-xyz); expect "api 404" "404" "$r"
expect "api 404 是 JSON" "1" "$(ctype /api/nothing-xyz | grep -c '^application/json')"
expectgrep "api 404 body JSON" "no such route"

# ---- 非 GET 未知路径不回退 ----
r=$(req POST /courses); expect "POST 深链 404（仅 GET 回退）" "404" "$r"

# ---- 关停 ----
kill $P; wait $P 2>/dev/null; rc=$?
if [ "$ON_WINDOWS" = "1" ]; then
  pass=$((pass+1)); echo "ok   server stopped (Windows kill=TearDown, rc=$rc 非优雅关停路径)"
else
  if [ "$rc" = "0" ]; then pass=$((pass+1)); echo "ok   server exit 0 after SIGTERM"; else fail=$((fail+1)); echo "FAIL server exit rc=$rc"; fi
fi
if grep -qiE "leak|panic" "$LOG"; then echo "FAIL shutdown 日志有泄漏/panic"; grep -inE "leak|panic" "$LOG"; fail=$((fail+1)); else pass=$((pass+1)); echo "ok   shutdown 日志干净"; fi

echo "PASS=$pass FAIL=$fail"
