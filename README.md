# mumu-skills

Hermes Agent 的备份/恢复技能对，用于把 Hermes 家目录全量打包加密上传网盘（OpenList WebDAV），以及在新机器上一键恢复。

## 技能

| 技能 | 作用 | 用法 |
|---|---|---|
| `hermes-backup` | 打包 HERMES_HOME 核心数据 + Hindsight PG dump → AES 加密 → 上传 OpenList 挂载的网盘 → 保留 N 版轮换 | `bash scripts/backup.sh`（含 `upload-hf-cache.sh` 一次性上传 HF 模型缓存） |
| `hermes-restore` | 在新机器装 OpenList → 挂网盘 → 拉取备份 → 解密解包 → 恢复清单（hindsight-all / PG 导入 / config 修正） | `bash scripts/restore.sh [备份名\|latest] [passphrase]` |

## 新服务器 bootstrap（完整闭环）

```bash
# 1. 装 Hermes
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# 2. 安装本仓库的两个技能
hermes skills install siyu1231/mumu-skills/hermes-backup --yes
hermes skills install siyu1231/mumu-skills/hermes-restore --yes

# 3. 照 hermes-restore SKILL.md 走：装 OpenList → 挂网盘（百度）→ 补权限位
# 4. 配置 ~/.hermes-backup.cfg（格式见 hermes-backup SKILL.md「前置」节，含 ALIST 地址/账号/密码/路径）
# 5. 恢复：先给旧机器发一条消息让配对批准带上，然后
HERMES_BACKUP_PASSPHRASE=<口令> bash <restore路径>/scripts/restore.sh latest
```

## 设计要点

- **加密**：备份包内含 .env（全部密钥），openssl AES-256-CBC + pbkdf2，口令存于 .env 的 `HERMES_BACKUP_PASSPHRASE`（在加密包内部，不构成泄露）
- **一致性**：state.db 用 sqlite backup API；Hindsight PG 用 pg_dump
- **配对**：`platforms/pairing/` 含微信等平台的用户批准记录，必须随包走（漏了会触发陌生人来配对流程）
- **外部工具盲区**：agently-cli 等装在 hermes home 之外的依赖，备份管不到——清单见 hermes-backup SKILL.md「外部工具清单」
- **网盘选型**：百度单盘（服务器侧两盘等效 ~350KB/s 限速）；大文件应急用「源机 tar + scp 直推」

## 实测记录（2026-09-07）

- Windows（本机）→ 腾讯云服务器全量迁移一次成功：技能、cron×21、微信账号态、Hindsight 记忆库（1034 条）
- 踩坑全部固化在各自 SKILL.md（权限位 bit9、MSYS/原生 curl 路径、OpenList fs/copy 卡死、pg_ctl 降权等）
