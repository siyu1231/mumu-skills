#!/usr/bin/env bash
# hermes-restore: 从 OpenList WebDAV 拉取备份 → 解密 → 解包到 HERMES_HOME
# 用法: restore.sh [备份文件名|latest] [passphrase]
set -euo pipefail

CFG_FILE="${HERMES_BACKUP_CFG:-$HOME/.hermes-backup.cfg}"
[ -f "$CFG_FILE" ] || { echo "ERROR: 缺 $CFG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CFG_FILE"
: "${ALIST_URL:?}" "${ALIST_USER:?}" "${ALIST_PASS:?}" "${WEBDAV_PATH:?}"

PICK="${1:-latest}"
echo "[1/5] 列远端备份…"
GW=$(pgrep -af "gateway run" 2>/dev/null | head -1)
[ -n "$GW" ] && echo "WARN: gateway 在运行，恢复会替换 state.db 致其 FATAL——恢复完需重启所有 hermes 进程" >&2
mapfile -t REMOTE < <(curl -fsS -u "$ALIST_USER:$ALIST_PASS" -X PROPFIND -H 'Depth: 1' "$ALIST_URL$WEBDAV_PATH/" | grep -oE 'hermes-backup-[0-9_]+\.tar\.gz\.enc' | sort -u)
[ "${#REMOTE[@]}" -gt 0 ] || { echo "ERROR: 远端无备份" >&2; exit 1; }
printf '       %s\n' "${REMOTE[@]}"
if [ "$PICK" = "latest" ]; then FILE="${REMOTE[-1]}"; else FILE="$PICK"; fi
echo "       选择: $FILE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[2/5] 下载…"
DL="$WORK/$FILE"
command -v cygpath >/dev/null 2>&1 && DL=$(cygpath -m "$DL")
curl -fsS -u "$ALIST_USER:$ALIST_PASS" -o "$DL" "$ALIST_URL$WEBDAV_PATH/$FILE"
echo "       $(du -h "$WORK/$FILE" | cut -f1)"

PASSPHRASE="${2:-${HERMES_BACKUP_PASSPHRASE:-}}"
if [ -z "$PASSPHRASE" ]; then
  for ENVTRY in "$HOME/.hermes/.env" "${LOCALAPPDATA:-/nonexistent}/hermes/.env"; do
    [ -f "$ENVTRY" ] && PASSPHRASE=$(grep -E '^HERMES_BACKUP_PASSPHRASE=' "$ENVTRY" | cut -d= -f2- || true) && break
  done
fi
[ -n "$PASSPHRASE" ] || { echo "ERROR: 缺 passphrase（参数2 或 HERMES_BACKUP_PASSPHRASE）" >&2; exit 1; }

echo "[3/5] 解密…"
DEC_IN="$WORK/$FILE"; DEC_OUT="$WORK/pkg.tar.gz"
if command -v cygpath >/dev/null 2>&1; then DEC_IN=$(cygpath -m "$DEC_IN"); DEC_OUT=$(cygpath -m "$DEC_OUT"); fi
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$PASSPHRASE" -in "$DEC_IN" -out "$DEC_OUT"

echo "[4/5] 解包…"
mkdir -p "$WORK/x" && tar xzf "$WORK/pkg.tar.gz" -C "$WORK/x"
[ -d "$WORK/x/hermes" ] || { echo "ERROR: 包结构异常（无 hermes/ 目录）" >&2; exit 1; }

# 目标 HERMES_HOME
if [ -z "${HERMES_HOME:-}" ]; then
  if [ -n "${LOCALAPPDATA:-}" ] && [ -d "$LOCALAPPDATA/hermes" ]; then HERMES_HOME="$LOCALAPPDATA/hermes"
  else HERMES_HOME="$HOME/.hermes"; fi
fi
command -v cygpath >/dev/null 2>&1 && echo "$HERMES_HOME" | grep -qE '^[A-Za-z]:[\\/]' && HERMES_HOME=$(cygpath -u "$HERMES_HOME")
if [ -f "$HERMES_HOME/config.yaml" ] && [ "${CONFIRM_OVERWRITE:-}" != "yes" ]; then
  echo "ERROR: $HERMES_HOME 已有 config.yaml。覆盖请加环境变量 CONFIRM_OVERWRITE=yes" >&2; exit 1
fi
mkdir -p "$HERMES_HOME"
# 覆盖前快照目标机现有敏感文件（可回滚）
for f in config.yaml .env auth.json; do
  [ -f "$HERMES_HOME/$f" ] && cp "$HERMES_HOME/$f" "$HERMES_HOME/$f.pre_restore" && echo "       快照 $f.pre_restore"
done
cp -r "$WORK/x/hermes/." "$HERMES_HOME/"
[ -f "$WORK/x/hermes-pg.sql.gz" ] && cp "$WORK/x/hermes-pg.sql.gz" "$HERMES_HOME/" && PGDUMP=yes || PGDUMP=no
echo "       已解包到 $HERMES_HOME（pg dump: $PGDUMP）"

echo "[4.3/5] 完整性自检…"
PY=$(command -v python3 || command -v python)
if [ -f "$HERMES_HOME/state.db" ]; then
  QC=$("$PY" - "$HERMES_HOME/state.db" <<'PYEOF'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    ok = c.execute("PRAGMA quick_check").fetchone()[0]
    n = c.execute("SELECT count(*) FROM sessions").fetchone()[0]
    print(f"{ok}|{n}")
except Exception as e:
    print(f"ERROR|{e}")
PYEOF
)
  case "$QC" in
    ok|*) echo "       state.db 完整，sessions=$(echo "$QC" | cut -d'|' -f2)" ;;
    *) echo "ERROR: state.db 损坏（$QC）——多半是解包被打断（恢复期间杀了 hermes 进程会截断大文件）。请重跑本脚本。" >&2; exit 1 ;;
  esac
else
  echo "ERROR: 解包后没有 state.db——解包不完整，请重跑本脚本" >&2; exit 1
fi

echo "[4.4/5] 回写 bootstrap 秘密（cfg/OpenList/网盘）…"
if [ -d "$WORK/x/hermes/bootstrap" ]; then
  B="$WORK/x/hermes/bootstrap"
  [ -f "$B/hermes-backup.cfg" ] && cp "$B/hermes-backup.cfg" "$HOME/.hermes-backup.cfg" && chmod 600 "$HOME/.hermes-backup.cfg" && echo "       ~/.hermes-backup.cfg ✓"
  [ -f "$B/openlist-admin-pass" ] && mkdir -p "$HOME/openlist" && cp "$B/openlist-admin-pass" "$HOME/openlist/.admin-pass" && chmod 600 "$HOME/openlist/.admin-pass" && echo "       ~/openlist/.admin-pass ✓"
  if [ -d "$B/openlist-data" ]; then
    mkdir -p "$HOME/openlist"
    [ -d "$HOME/openlist/data" ] && mv "$HOME/openlist/data" "$HOME/openlist/data.pre_restore.$(date +%s)" && echo "       已有 openlist/data 移备"
    cp -r "$B/openlist-data" "$HOME/openlist/data" && echo "       ~/openlist/data ✓（网盘挂载+token 随包恢复，免扫码；装好 OpenList 启动即用）"
  fi
else
  echo "       包内无 bootstrap（旧版备份）——网盘/OpenList 需手工配置"
fi

echo "[4.5/5] HF 模型缓存（网盘有则拉，免去 HF 下载）…"
HF_DL="$WORK/hf.tar.gz"
command -v cygpath >/dev/null 2>&1 && HF_DL=$(cygpath -m "$HF_DL")
if curl -fsS -u "$ALIST_USER:$ALIST_PASS" -o "$HF_DL" "$ALIST_URL$WEBDAV_PATH/hermes-hf-cache.tar.gz" 2>/dev/null; then
  mkdir -p ~/.cache/huggingface/hub && tar xzf "$WORK/hf.tar.gz" -C ~/.cache/huggingface/hub && echo "       HF 缓存已恢复（zh 嵌入 + reranker）"
else
  echo "       网盘无 hf-cache，按 skill 用 hf-mirror 预热"
fi

echo "[5/5] 后续必做（详见 skill hermes-restore「恢复后必做清单」）:"
echo "  1) venv 装 hindsight-all；2) pg 恢复 hermes-pg.sql.gz（HF 缓存已拉则跳过预热）"
echo "  3) hermes config set terminal.cwd <路径>；删 gateway.pid/gateway.lock"
echo "  4) 起 gateway；5) 验证 memory status / 平台消息 / cron / MCP"
echo "DONE"
