#!/usr/bin/env bash
set -u
cd /Users/by/project/zig/crm
BIN=./zig-out/bin/crm
BASE=http://127.0.0.1:8080
DIR=.dbg
mkdir -p "$DIR"
J=$DIR/adm.jar
rm -f $J

pkill -9 -x crm 2>/dev/null; sleep 1
rm -f data/crm.db data/crm.db-wal data/crm.db-shm

zig build >$DIR/build.log 2>&1
echo "build rc=$?"
md5 "$BIN"

"$BIN" >$DIR/server.log 2>&1 &
P=$!
for i in $(seq 1 60); do curl -sf "$BASE/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
echo "server pid=$P health=$(curl -s -w ' %{http_code}' "$BASE/api/health" -o /dev/null)"

curl -s -x -o $DIR/login.json -w 'login=%{http_code}\n' -c $J -b $J -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -d '{"account":"admin","password":"admin123456"}'

echo "--- create category ---"
curl -s -o $DIR/last.json -w 'POST=%{http_code} ' -b $J -c $J -X POST "$BASE/api/admin/categories" -H 'Content-Type: application/json' -d '{"parent_id":0,"name":"测试分类XYZ","sort":55}'
echo " body=$(cat $DIR/last.json)"
CID=$(python3 -c "import json;print(json.load(open('$DIR/last.json'))['data']['id'])")
echo "CID=$CID"

echo "--- PUT category ---"
curl -s -o $DIR/last.json -w 'PUT=%{http_code} ' -b $J -c $J -X PUT "$BASE/api/admin/categories/$CID" -H 'Content-Type: application/json' -d '{"parent_id":0,"name":"测试分类XYZ(改)","sort":56}'
echo " body=$(cat $DIR/last.json)"

echo "--- DELETE category ---"
curl -s -o $DIR/last.json -w 'DELETE=%{http_code} ' -b $J -c $J -X DELETE "$BASE/api/admin/categories/$CID"
echo " body=$(cat $DIR/last.json)"

echo "--- GET category missing (expect 404) ---"
curl -s -o $DIR/last.json -w 'GET=%{http_code} ' "$BASE/api/admin/categories/99999"
echo " body=$(cat $DIR/last.json)"

kill -TERM $P; wait $P 2>/dev/null
echo "server exit=$?"
echo "--- server log ---"; grep -vE "^(INFO|health)" $DIR/server.log | tail -8
