#!/usr/bin/env bash
# hermes-backup: 打包 Hermes 家目录 + Hindsight PG → AES 加密 → WebDAV 上传 → 轮换
# 平台: Windows Git Bash / Linux 通用
deleted_count=0
set -euo pipefail

# ── HERMES_HOME 探测（Windows: $LOCALAPPDATA/hermes；Linux: ~/.hermes）──
if [ -z "${HERMES_HOME:-}" ]; then
  if [ -n "${LOCALAPPDATA:-}" ] && [ -f "$LOCALAPPDATA/hermes/config.yaml" ]; then
    HERMES_HOME="$LOCALAPPDATA/hermes"
  elif [ -f "$HOME/.hermes/config.yaml" ]; then
    HERMES_HOME="$HOME/.hermes"
  else
    echo "ERROR: 找不到 HERMES_HOME" >&2; exit 1
  fi
fi
# Windows 盘符路径转 MSYS（tar/cp 需要）
if command -v cygpath >/dev/null 2>&1 && echo "$HERMES_HOME" | grep -qE '^[A-Za-z]:[\\/]'; then
  HERMES_HOME=$(cygpath -u "$HERMES_HOME")
fi
echo "[0/6] HERMES_HOME=$HERMES_HOME"

CFG_FILE="${HERMES_BACKUP_CFG:-$HOME/.hermes-backup.cfg}"
[ -f "$CFG_FILE" ] || { echo "ERROR: 缺 $CFG_FILE（见 skill 前置节）" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CFG_FILE"
: "${ALIST_URL:?}" "${ALIST_USER:?}" "${ALIST_PASS:?}" "${WEBDAV_PATH:?}"
KEEP="${KEEP:-5}"

PASSPHRASE="${HERMES_BACKUP_PASSPHRASE:-}"
if [ -z "$PASSPHRASE" ]; then
  PASSPHRASE=$(grep -E '^HERMES_BACKUP_PASSPHRASE=' "$HERMES_HOME/.env" 2>/dev/null | cut -d= -f2- || true)
fi
[ -n "$PASSPHRASE" ] || { echo "ERROR: 缺 HERMES_BACKUP_PASSPHRASE（env 或 $HERMES_HOME/.env）" >&2; exit 1; }

PY=$(command -v python || command -v python3 || true)
[ -n "$PY" ] || { echo "ERROR: 无 python" >&2; exit 1; }

TS=$(date +%Y%m%d_%H%M%S)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DEST="$WORK/hermes"
mkdir -p "$DEST"

echo "[1/6] 拷贝核心文件…"
for f in config.yaml .env auth.json SOUL.md channel_directory.json gateway_state.json projects.db kanban.db spawn-ledger.json; do
  [ -f "$HERMES_HOME/$f" ] && cp "$HERMES_HOME/$f" "$DEST/" || true
done
for d in skills memories hindsight weixin pairing platforms scripts hooks kanban sessions cron attachments identity; do
  if [ -d "$HERMES_HOME/$d" ]; then
    mkdir -p "$DEST/$d"
    cp -r "$HERMES_HOME/$d/." "$DEST/$d/" 2>/dev/null || true
  fi
done
rm -f "$DEST/cron/executions.db"* 2>/dev/null || true

if [ -f "$HERMES_HOME/state.db" ]; then
  SRC_DB="$HERMES_HOME/state.db"; DST_DB="$DEST/state.db"
  if command -v cygpath >/dev/null 2>&1; then SRC_DB=$(cygpath -m "$SRC_DB"); DST_DB=$(cygpath -m "$DST_DB"); fi
  "$PY" - "$SRC_DB" "$DST_DB" <<'PYEOF'
import sqlite3, sys
s = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
d = sqlite3.connect(sys.argv[2])
s.backup(d); d.close(); s.close()
print("       state.db 一致性备份 ok")
PYEOF
fi

echo "[2/6] pg_dump Hindsight 记忆库…"
PGDIR="$HOME/.pg0"
if command -v cygpath >/dev/null 2>&1; then PGDIR_PY=$(cygpath -m "$PGDIR"); else PGDIR_PY="$PGDIR"; fi
if [ -d "$PGDIR/instances" ]; then
  eval "$("$PY" - "$PGDIR_PY" <<'PYEOF'
import json, sys, glob, os, shlex
inst = sorted(glob.glob(os.path.join(sys.argv[1], 'instances', '*', 'instance.json')))
if inst:
    d = json.load(open(inst[-1], encoding='utf-8'))
    all_bins = glob.glob(os.path.join(sys.argv[1], 'installation', '*', 'bin', 'pg_dump*'))
    dumps = [b for b in all_bins if os.path.basename(b).lower() in ('pg_dump', 'pg_dump.exe')]
    print('PG_PORT=%s' % d.get('port', ''))
    print('PG_USER=%s' % shlex.quote(str(d.get('user') or d.get('username') or '')))
    print('PG_DB=%s' % shlex.quote(str(d.get('database') or d.get('dbname') or 'postgres')))
    print('PG_PASS=%s' % shlex.quote(str(d.get('password') or '')))
    print('PG_DUMP=%s' % shlex.quote(dumps[-1] if dumps else ''))
PYEOF
)"
  if [ -n "${PG_DUMP:-}" ] && [ -n "${PG_PORT:-}" ]; then
    if PGPASSWORD="$PG_PASS" "$PG_DUMP" -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" "$PG_DB" 2>"$WORK/pgerr.log" | gzip > "$WORK/hermes-pg.sql.gz"; then
      echo "       pg_dump ok ($(du -h "$WORK/hermes-pg.sql.gz" | cut -f1))"
    else
      echo "       WARN: pg_dump 失败（PG 未运行?）跳过: $(tail -1 "$WORK/pgerr.log")"
      rm -f "$WORK/hermes-pg.sql.gz"
    fi
  else
    echo "       WARN: 未找到 pg_dump 或端口，跳过"
  fi
else
  echo "       无 ~/.pg0，跳过"
fi

echo "[3/6] 打包 tar.gz…"
tar czf "$WORK/pkg.tar.gz" -C "$WORK" hermes $( [ -f "$WORK/hermes-pg.sql.gz" ] && echo hermes-pg.sql.gz )
PKG_SIZE=$(du -h "$WORK/pkg.tar.gz" | cut -f1)
echo "       包大小 $PKG_SIZE"

echo "[4/6] 加密…"
FILE="hermes-backup-$TS.tar.gz.enc"
ENC_IN="$WORK/pkg.tar.gz"; ENC_OUT="$WORK/$FILE"
if command -v cygpath >/dev/null 2>&1; then ENC_IN=$(cygpath -m "$ENC_IN"); ENC_OUT=$(cygpath -m "$ENC_OUT"); fi
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "pass:$PASSPHRASE" -in "$ENC_IN" -out "$ENC_OUT"
rm -f "$WORK/pkg.tar.gz"

echo "[5/6] 上传 WebDAV…"
UP="$WORK/$FILE"
command -v cygpath >/dev/null 2>&1 && UP=$(cygpath -w "$UP")
curl -fsS -u "$ALIST_USER:$ALIST_PASS" -T "$UP" "$ALIST_URL$WEBDAV_PATH/$FILE" -w '       PUT %{http_code} %{size_upload}B\n'

echo "[6/6] 轮换（保留 $KEEP）…"
mapfile -t REMOTE < <(curl -fsS -u "$ALIST_USER:$ALIST_PASS" -X PROPFIND -H 'Depth: 1' "$ALIST_URL$WEBDAV_PATH/" | grep -oE 'hermes-backup-[0-9_]+\.tar\.gz\.enc' | sort -u)
TOTAL=${#REMOTE[@]}
echo "       远端共 $TOTAL 份"
if [ "$TOTAL" -gt "$KEEP" ]; then
  for ((i=0; i<TOTAL-KEEP; i++)); do
    curl -fsS -u "$ALIST_USER:$ALIST_PASS" -X DELETE "$ALIST_URL$WEBDAV_PATH/${REMOTE[$i]}" -w '       删除旧版 %{http_code}: ' 
    echo "${REMOTE[$i]}"
    deleted_count=$((deleted_count+1))
  done
fi
echo "DONE: $FILE ($PKG_SIZE)，远端保留 $((TOTAL-deleted_count)) 份"
