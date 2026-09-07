---
name: hermes-restore
description: Use when 从网盘恢复/迁移 Hermes 到新机器：装 OpenList、拉备份、解密解包、机器修正。
tags: [hermes, restore, migration, openlist, webdav, 迁移, 网盘]
---

# Hermes 从网盘恢复 / 迁移到新机器

配套 skill：`hermes-backup`（备份侧）。本 skill 覆盖：OpenList 安装配置（两平台）→ 拉取备份 → 解密解包 → 机器修正 → 验证。

## OpenList 安装配置（实测 2026-09，v4.2.6）

### Windows（本机已验证路径）

```bash
curl -fsSL -o openlist.zip https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-windows-amd64.zip
mkdir -p /c/Users/<user>/openlist && cd /c/Users/<user>/openlist && unzip -o <openlist.zip>
./openlist.exe admin set '<强密码>'     # 存到 .admin-pass (chmod 600)
./openlist.exe server                  # 后台跑；常驻用 Scheduled Task 包一层
```

### Linux（服务器）

```bash
curl -fsSL -o openlist.tar.gz https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-linux-amd64.tar.gz
mkdir -p ~/openlist && tar xzf openlist.tar.gz -C ~/openlist && cd ~/openlist
./openlist admin set '<强密码>'
# systemd 用户服务 ~/openlist/openlist.service → systemctl --user enable --now（Linger=yes）
```

### 挂网盘（百度网盘为例，单盘方案）

1. 管理界面 http://localhost:5244 → 存储 → 添加 → 百度网盘
2. **refresh token 获取**（无需开发者权限，用在线 API 方法）：
   - 工具页 https://api.oplist.org/ → 网盘服务下拉选「百度网盘」→ 勾「使用 OpenList 提供的参数」→ 获取 Token → 百度授权
   - 页面找不到按钮时的直链兜底（实测有效）：先开 `https://api.oplist.org/baiduyun/requests?driver_txt=baiduyun_go&server_use=true`（种 cookie + 返回 JSON），再把 JSON 里 text 的 openapi.baidu.com 授权链接贴进地址栏 → 授权 → 跳回显示 refresh token
   - token 是**和应用绑定**的：别处拿的 token 会报 `empty token returned from official API`
3. 配置页：粘 refresh token + **勾「使用在线API」** + 挂载路径填虚拟路径（如 `/baidu`，**不是** Windows 盘符路径）+ web_proxy 开 + webdav_policy=native_proxy（>20MB 下载必须走中转）
4. **admin 补 WebDAV 写权限**（v4 默认 29183 缺 bit9，写操作 403）：
   ```bash
   TOKEN=$(curl -s -X POST localhost:5244/api/auth/login -H 'Content-Type: application/json' -d '{"username":"admin","password":"<pw>"}' | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
   curl -s -X POST localhost:5244/api/admin/user/update -H "Authorization: $TOKEN" -H 'Content-Type: application/json' -d '{"id":1,"username":"admin","password":"","base_path":"/","role":2,"disabled":false,"permission":29695,"sso_id":"","allow_ldap":true}'
   ```
5. 验证：PROPFIND 列目录 + MKCOL/PUT/DELETE 各一次
6. 写 `~/.hermes-backup.cfg`（格式见 hermes-backup skill 前置节）

## 恢复执行

```bash
bash <本skill目录>/scripts/restore.sh [备份文件名|latest] [passphrase]
```

passphrase 优先级：参数2 > 环境变量 HERMES_BACKUP_PASSPHRASE > 目标机 .env。全新机器用参数或环境变量。

## 恢复后必做清单（按序）

1. **venv 依赖**：Hindsight local_embedded 需 `uv pip install --python <hermes venv python> hindsight-all`（200MB+；服务器装前确认 RAM ≥ 1G 空闲）
2. **HF 模型**（国内网络）：.env 已在包内（HF_ENDPOINT=hf-mirror.com 等），但模型文件要重新下载，预热：
   `HF_ENDPOINT=https://hf-mirror.com HF_HUB_DISABLE_XET=1 python -c "from huggingface_hub import snapshot_download; snapshot_download('BAAI/bge-small-zh-v1.5')"`
3. **PG 记忆库**：跑一次 hermes 触发 hindsight daemon 初始化 pg0 实例 → 导入 dump（实测命令序列）：
   ```bash
   PSQL=~/.pg0/installation/18.1.0/bin/psql
   PGPASSWORD=$(python3 -c "import json;print(json.load(open('$HOME/.pg0/instances/hindsight-embed-hermes/instance.json'))['password'])")
   $PSQL -h 127.0.0.1 -p 5432 -U hindsight -d hindsight -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
   zcat ~/.hermes/hermes-pg.sql.gz | $PSQL -h 127.0.0.1 -p 5432 -U hindsight -d hindsight -q -v ON_ERROR_STOP=0
   $PSQL -h 127.0.0.1 -p 5432 -U hindsight -d hindsight -t -c "SELECT count(*) FROM memory_units;"  # 期望 >0（迁移时 1034）
   ```
   另：恢复后检查 `~/.hermes/hindsight/config.json` 的 `mode` 必须是 `local_embedded`（曾被写成 local_external 导致 retain 静默空转的踩坑）
4. **机器修正**：`hermes config set terminal.cwd <新机路径>`；删 gateway.pid/gateway.lock/.mcp-discovery.lock
5. **托管**：systemd --user / Scheduled Task 起 gateway
6. **验证**：hermes memory status（available ✓）→ 平台发消息有回复 → cron jobs 数量 → MCP 工具可用

## 坑

- 备份包内含 .env（全部密钥）→ 传输/存储全程加密，解密只在目标机本地做
- 微信同账号两端互踢：恢复验证前停掉旧机器的 gateway
- state.db / cron jobs.json 跨版本恢复前先对齐两端 hermes commit