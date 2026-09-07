#!/usr/bin/env bash
# upload-hf-cache: 本地 HF 模型缓存（hindsight 嵌入+reranker）一次性上传网盘
# 只需跑一次；restore 侧优先从网盘拉，拉不到才走 hf-mirror
set -euo pipefail
CFG_FILE="${HERMES_BACKUP_CFG:-$HOME/.hermes-backup.cfg}"
[ -f "$CFG_FILE" ] || { echo "ERROR: 缺 $CFG_FILE" >&2; exit 1; }
. "$CFG_FILE"
: "${ALIST_URL:?}" "${ALIST_USER:?}" "${ALIST_PASS:?}" "${WEBDAV_PATH:?}"

HFHUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"
MODELS="models--BAAI--bge-small-zh-v1.5 models--cross-encoder--ms-marco-MiniLM-L-6-v2"
for m in $MODELS; do
  [ -d "$HFHUB/$m" ] || { echo "ERROR: 缺 $HFHUB/$m" >&2; exit 1; }
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "打包 HF 缓存…"
tar czf "$WORK/hermes-hf-cache.tar.gz" -C "$HFHUB" $MODELS
echo "包大小 $(du -h "$WORK/hermes-hf-cache.tar.gz" | cut -f1)"
UP="$WORK/hermes-hf-cache.tar.gz"
command -v cygpath >/dev/null 2>&1 && UP=$(cygpath -w "$UP")
curl -fsS -u "$ALIST_USER:$ALIST_PASS" -T "$UP" "$ALIST_URL$WEBDAV_PATH/hermes-hf-cache.tar.gz" -w 'PUT %{http_code} %{size_upload}B\n'
echo "DONE"
