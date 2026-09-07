# mumu-skills

Hermes Agent 的备份/恢复技能对，用于把 Hermes 家目录全量打包加密上传网盘（OpenList WebDAV），以及在新机器上一键恢复。

## 技能

| 技能 | 作用 | 用法 |
|---|---|---|
| `hermes-backup` | 打包 HERMES_HOME 核心数据 + Hindsight PG dump → AES 加密 → 上传 OpenList 挂载的网盘 → 保留 N 版轮换 | `bash scripts/backup.sh`（含 `upload-hf-cache.sh` 一次性上传 HF 模型缓存） |
| `hermes-restore` | 在新机器装 OpenList → 挂网盘 → 拉取备份 → 解密解包 → 自动回写 bootstrap 配置 → 恢复清单 | `bash scripts/restore.sh [备份名\|latest]` |

> **从零恢复只缺两个秘密**：解密口令（HERMES_BACKUP_PASSPHRASE，用户记/密码管理器）+ 百度网盘 token（首次挂盘用，之后机器自持）。

---

## 从零开始：新服务器完整步骤（实测 2026-09-07 逐条验证）

> 警告：从聊天工具复制命令时，注意别把链接包装符（如 `@url:`）带进终端——`git config` 和 `export` 里混入会静默失效。下面命令均为干净文本。

### 0. 服务器要求

- Ubuntu 22.04/24.04，**内存 ≥ 4G**（1.9G 实测两小时崩两次：gateway + hindsight daemon + OpenList 常驻 ≈1.7G）
- 国内网络需走镜像（本指南已内置）

### 1. 装 Hermes（国内网络版）

```bash
# ① git 走镜像 + HTTP/1.1（防 github 超时和 HTTP2 帧错误）
git config --global url."https://ghfast.top/https://github.com".insteadOf "https://github.com"
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000

# ② pip 走清华镜像
export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
export PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# ③ 安装（官方脚本；clone 走镜像，67MB ≈ 10s）
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
# 如官方脚本装不上，备选国内镜像版：curl -fsSL https://hermes-agent.ac.cn/install.sh | bash
#   （注意：镜像版把源码仓库指到 gitcode.com 镜像，装完建议核验 commit 与官方一致）

# ④ 临时配一个 LLM key（恢复前 agent 跑不起来；恢复后 .env 会被完整版覆盖）
mkdir -p ~/.hermes && echo 'DEEPSEEK_API_KEY=<你的key>' >> ~/.hermes/.env
hermes config set model.default deepseek-v4-flash
hermes config set model.provider deepseek
```

### 2. 拿本仓库的两个 skill

```bash
# 方式 A：CLI 直装（registry 可达时）
hermes skills install siyu1231/mumu-skills/hermes-backup --yes
hermes skills install siyu1231/mumu-skills/hermes-restore --yes

# 方式 B：git clone（国内最稳，实测路径）
cd /root && rm -rf mumu-skills
git clone https://github.com/siyu1231/mumu-skills.git 2>/dev/null \
  || git clone https://ghfast.top/https://github.com/siyu1231/mumu-skills.git
# 之后用到 restore.sh 就指 /root/mumu-skills/hermes-restore/scripts/restore.sh
```

### 3. 装 OpenList（网盘中转站）

```bash
curl -fsSL --connect-timeout 15 --max-time 280 -o /tmp/ol.tar.gz \
  https://github.com/OpenListTeam/OpenList/releases/download/v4.2.6/openlist-linux-amd64.tar.gz \
  || curl -fsSL --max-time 280 -o /tmp/ol.tar.gz \
  https://ghfast.top/https://github.com/OpenListTeam/OpenList/releases/download/v4.2.6/openlist-linux-amd64.tar.gz
mkdir -p ~/openlist && tar xzf /tmp/ol.tar.gz -C ~/openlist && chmod +x ~/openlist/openlist && rm /tmp/ol.tar.gz
cd ~/openlist && ./openlist admin set '<设个密码>'
echo '<设个密码>' > ~/openlist/.admin-pass && chmod 600 ~/openlist/.admin-pass
nohup ./openlist server > ~/openlist/server.log 2>&1 &   # 长期跑建议 systemd 用户服务
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5244   # 200 = OK
```

### 4. 挂百度网盘

**admin 补 WebDAV 写权限**（v4 默认缺 bit9，写操作会 403）：
```bash
# 1) 取登录 token（返回 JSON 的 data.token）
curl -s -X POST localhost:5244/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<openlist密码>"}'
# 2) 把上一步 data.token 粘进下面占位符再执行：
HEADER='Authorization: Bearer <粘贴token>'
curl -s -X POST localhost:5244/api/admin/user/update -H "$HEADER" \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"username":"admin","password":"","base_path":"/","role":2,"disabled":false,"permission":29695,"sso_id":"","allow_ldap":true}'
```

**刷新令牌（Refresh Token）获取**（在线 API 法，免开发者权限）：
- 浏览器打开 https://api.oplist.org/ → 网盘服务下拉选「百度网盘」→ 勾「使用 OpenList 提供的参数」→ 获取 Token → 百度扫码授权 → 复制「刷新令牌」
- 找不到按钮时的直链兜底：先访问 `https://api.oplist.org/baiduyun/requests?driver_txt=baiduyun_go&server_use=true`（返回 JSON 并种 cookie），再把 JSON 里 text 字段的 openapi.baidu.com 链接贴地址栏 → 授权 → 跳回拿 token

**管理界面加存储**（http://localhost:5244 → 存储 → 添加 → 百度网盘）：
| 字段 | 填 |
|---|---|
| 刷新令牌 | 上面拿到的 |
| 使用在线API | ✅ 勾选 |
| client_id / secret | 留空 |
| 挂载路径 | `/baidu`（虚拟路径，不是盘符） |
| web_proxy / webdav 策略 | 开 / 本机代理（>20MB 下载必须） |

验证读写：浏览器进 /baidu 能看到文件列表即通。

### 5. 写备份配置

```bash
cat > ~/.hermes-backup.cfg <<'EOF'
ALIST_URL=http://localhost:5244
ALIST_USER=admin
ALIST_PASS=<openlist密码>
WEBDAV_PATH=/dav/baidu/hermes-backups
KEEP=5
EOF
chmod 600 ~/.hermes-backup.cfg
```

### 6. 恢复（⚠️ 必须在 tmux 里手动跑，绝不让 hermes agent 代跑）

> 原因：restore.sh 会整体替换 state.db——由 hermes 代跑等于锯自己坐的树枝，实测导致 state.db 截断损坏。

```bash
tmux new-session -s restore        # 防断线；完成后 Ctrl-b 然后 d 退出
pkill -f hermes 2>/dev/null; sleep 2   # 先停所有 hermes 进程
CONFIRM_OVERWRITE=yes HERMES_BACKUP_PASSPHRASE=<口令> \
  bash /root/mumu-skills/hermes-restore/scripts/restore.sh latest 2>&1 | tee /root/restore.log
# 百度网盘 121M 约 30 分钟（限速 ~70KB/s），看到 DONE 才算完
```

### 7. 恢复后验证

```bash
# state.db 完整性（应输出 ok + 会话数）
python3 -c "import sqlite3; c=sqlite3.connect('/root/.hermes/state.db'); print(c.execute('PRAGMA quick_check').fetchone()[0], c.execute('select count(*) from sessions').fetchone()[0])"

# 起 gateway 并验证（微信/cron/MCP）
pkill -f hermes 2>/dev/null; sleep 1
nohup hermes gateway run > ~/.hermes/logs/gateway.log 2>&1 &   # 或 systemd 用户服务
hermes memory status      # 应 available ✓（hindsight 若没装先跑：
                          #  python -m ensurepip && pip install -i https://pypi.tuna.tsinghua.edu.cn/simple hindsight-all）
```

---

## 常见坑速查（全部实测踩过）

| 症状 | 原因 | 解法 |
|---|---|---|
| `database disk image is malformed` | 恢复期间杀了 hermes → cp 截断 state.db | 重跑 restore.sh（内含 4.3 步完整性自检） |
| `FATAL: state.db was replaced underneath` | 有 hermes 进程活着时恢复了数据 | 恢复前 `pkill -f hermes` |
| restore.sh 打出 [1/5] 就静默退出 | 旧版 gateway 检查在无进程时触发 set -e | `git pull` 更新脚本（459154c 已修） |
| git clone 直连 github 超时 | 国内网络 | ghfast 镜像 + `http.version HTTP/1.1` |
| `curl 16 HTTP2 framing layer` | 镜像/弱网 | `git config --global http.version HTTP/1.1` |
| 从聊天复制命令带 `@url:` 前缀 | 链接包装符 | 删掉或手动重敲 |
| OpenList 写操作 403 | admin 权限缺 bit9 | 第 4 步的 permission=29695 命令 |
| 百度下载只有 ~70KB/s | 第三方客户端限速 | 接受（30 分钟/包）或源机 tar+scp 直推（~9MB/s） |

## 设计要点

- **单秘密原则**：口令（HERMES_BACKUP_PASSPHRASE）是唯一留在加密包外的秘密，绝不传网盘（钥匙不能和箱子同放），存密码管理器或记忆
- **bootstrap 自动回写**：cfg / OpenList admin 密码 / OpenList data（含网盘 token）已收进加密包，restore 解包后自动落位——除首次挂盘外零手工
- **一致性**：state.db 用 sqlite backup API；Hindsight PG 用 pg_dump
- **配对**：`platforms/pairing/` 含平台用户批准记录，必须随包走（漏了会触发陌生人来配对流程）
- **外部工具盲区**：agently-cli 等 hermes home 外的依赖备份管不到——清单见 hermes-backup SKILL.md「外部工具清单」，恢复后按清单补

## 实测记录（2026-09-07）

- Windows 本机 → 云服务器全量迁移：技能、cron×21、微信账号态、Hindsight 记忆库（1034 条）一次成功
- 云服务器 1.9G 内存两小时崩两次 → 换 ≥4G 的教训
- 所有踩坑固化在 SKILL.md + 本 README（权限位 bit9、set -e 静默退出、state.db 运行时替换保护、pg_ctl 管道挂死、MSYS/原生 curl 路径等）
