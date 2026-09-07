---
name: hermes-backup
description: Use when 备份/打包 Hermes 到网盘（OpenList WebDAV）或配置定时备份。加密上传+轮换。
tags: [hermes, backup, openlist, webdav, 网盘, 迁移]
---

# Hermes 网盘备份（OpenList 管道）

把 HERMES_HOME 核心数据 + Hindsight PG 全量 dump 打包 → openssl AES 加密 → curl WebDAV 上传到 OpenList 挂载的网盘 → 保留最近 KEEP 份。恢复/迁移用配套 skill `hermes-restore`。

## 执行

```bash
bash <本skill目录>/scripts/backup.sh
```

成功输出上传大小 + 远端文件列表。失败信息带步骤号（1/6 拷贝 → 6/6 轮换），按号定位。

## 前置（每台机器一次性配置）

1. **OpenList 运行中**（安装配置全流程见 skill `hermes-restore` 的「OpenList 安装配置」节，两平台通用）
2. **网盘驱动已挂载**且 WebDAV 读写验证过（MKCOL/PUT/DELETE 全通）
3. **`~/.hermes-backup.cfg`**（0600）：
   ```
   ALIST_URL=http://localhost:5244
   ALIST_USER=admin
   ALIST_PASS=<openlist admin 密码>
   WEBDAV_PATH=/dav/<挂载名>/hermes-backups
   KEEP=5
   ```
4. **`.env` 里加 `HERMES_BACKUP_PASSPHRASE=<32位hex>`**。它随备份包走（在加密包内部，不构成泄露）；恢复新机器后该机器的 .env 自动带上，后续备份无感。

## 备份内容（忠实口径）

- 单文件：config.yaml / .env / auth.json / SOUL.md / channel_directory.json / gateway_state.json / projects.db / kanban.db / spawn-ledger.json
- 目录：skills/ memories/ hindsight/ weixin/（微信账号态） pairing/ platforms/（**配对批准在 platforms/pairing/，漏了会触发陌生人来配对流程**） scripts/ hooks/ kanban/ sessions/ cron/（只留 jobs.json） attachments/ identity/
- state.db：sqlite backup API 一致性拷贝（**绝不直接 cp 活库**）
- ~/.pg0 的 Hindsight 内嵌 PG：pg_dump 全量（实例连接信息从 instance.json 解析）；PG 没在跑则警告跳过。**但全量迁移前必须保证 dump 成功**——若 PG 没在跑（daemon 懒启动、CLI 退出即死），先 standalone 拉起：
  ```bash
  PGBIN=$(ls -d ~/.pg0/installation/*/bin | head -1)
  "$PGBIN/pg_ctl.exe" -D "$(cygpath -w ~/.pg0/instances/hindsight-embed-hermes/data)" -w -t 120 start  # Windows；Linux 用 pg_ctl（无 .exe）
  bash <backup.sh>
  "$PGBIN/pg_ctl.exe" -D "$(cygpath -w ~/.pg0/instances/hindsight-embed-hermes/data)" -m fast stop
  ```
  注意：Windows 上不能直接跑 postgres.exe（拒绝 Administrator 权限运行），必须 pg_ctl（它会降权拉起）。
- 明确排除：logs/ cache/ node/ hermes-agent/（重装即有）bin/ lsp/ pets/ state.db-wal/shm models 缓存

## HF 模型缓存（一次性）

hindsight 依赖的嵌入/reranker 模型（bge-small-zh-v1.5 + ms-marco-MiniLM-L-6-v2，~270M）本地下载好后**只需上传一次**：

```bash
bash <本skill目录>/scripts/upload-hf-cache.sh
```

产物 `hermes-hf-cache.tar.gz` 放备份同目录。restore 侧优先从网盘拉它（restore.sh 已内置），拉不到才走 hf-mirror 下载——新机器恢复不依赖 HF 网络。模型不变就不用重传。

## 定时备份（cronjob）

用户确认后用 cronjob 工具建：schedule 如 `every day at 4:30am`，prompt 自包含（执行本 skill 的 backup.sh，汇报上传大小与远端保留份数），deliver 到用户渠道。备份期间 gateway 不用停（sqlite/pg_dump 都是一致性快照）。

## 网盘选型（实测 2026-09，结论：百度单盘）

服务器（Tencent 云 IP）视角测速，两网盘**等效**：上传都 ~350KB/s，下载都被限（百度 42KB/s；阿里首 ~100M 快后限 ~90KB/s）。本机上传虽阿里快（17.5MB/s vs 百度 1MB/s），但本机已退役——故简化为**百度单盘**（WEBDAV_PATH=/dav/baidu/hermes-backups）。

- nightly 备份 117M ≈ 6 分钟上传，可接受；restore 下载慢是常态，应急用「源机 tar+scp 直推」（~9MB/s）兜底
- OpenList 内部 fs/copy 跨盘复制大文件实测**卡死**（uploading 进度 0）→ 用 curl 经本机中转
- 阿里云盘 token：api.oplist.org 网盘服务选「阿里云盘 - 扫码登录」扫码即得（如将来换回）

## 外部工具清单（hermes home 之外，备份管道管不到，恢复后需手动补齐）

| 依赖 | 安装/授权 | 位置 |
|---|---|---|
| agently-cli（agent.qq.com 邮件） | `npm install -g @tencent-qqmail/agently-cli` + `agently-cli auth login`（OAuth，token 存 CLI 私有位置，不随家目录走） | npm 全局 + ~/.agently-cli（仅 app_id） |
| node/npm | apt/官方源 | /usr/bin |
| OpenList | 见 hermes-restore skill 安装节（含网盘 token，重建时重新授权） | ~/openlist |
| HF 模型缓存 | 用 scripts/upload-hf-cache.sh 上传，restore 自动拉 | ~/.cache/huggingface |

## 口令设计（单秘密原则，2026-09-07 用户问答沉淀）

**口令（HERMES_BACKUP_PASSPHRASE）绝不上传网盘**——网盘上是密文、口令是钥匙，钥匙和锁着的箱子放同一处 = 加密作废。口令唯一归宿：用户的密码管理器（Bitwarden/1Password/浏览器密码库），首次恢复时手输一次。

**单秘密 bootstrap**：恢复新机器只应搬运这一个秘密。其余一切（API keys、微信 token、网盘 token、OpenList 密码、备份 cfg）都应在加密包内。当前缺口（待改）：`~/.hermes-backup.cfg`、网盘 storage token（OpenList 的 data 目录）、OpenList admin 密码还在包外，恢复时要手工重配——**待办**：backup.sh 把这三样收进加密包，restore.sh 解出后自动写回，实现真正的「输一次口令走全程」。

## 坑（实测 2026-09）

- **WebDAV 403 但读正常** = OpenList 用户权限位缺 bit9（WebDAV 写入）。v4 默认 admin permission=29183（缺 bit9）→ API 改 29695：`POST /api/admin/user/update`（见 restore skill 安装节命令）
- **Windows native curl 不认 /dev/null**（exit 23，输出全无）：脚本内一律不 `-o /dev/null`；`-T` 的本地文件路径先 cygpath -w
- OpenList 后台进程随 Hermes 会话退出而死 → 常驻要 Scheduled Task（本机）/ systemd（服务器），见 restore skill
- **pg_ctl 输出别接 `| tail` 管道**：pg_ctl 拉起的 postgres 继承 stdout，管道永远等不到 EOF，整条命令链挂死数小时（实测 2026-09-07 掛 4.5h）。正确：pg_ctl 独立后台跑或 `-l logfile` 重定向。
- 百度网盘 >20MB 下载需本机中转（web_proxy + webdav_policy=native_proxy，建存储时已配好）