# compose-watchdog

> **一个文件、零依赖、零配置的 Docker Compose 服务看门狗**：容器被健康检查标为 `unhealthy` 时，
> 由 cron 驱动自动按依赖序重建，典型僵死场景 **约 3 分钟自愈**，无需人工介入。

> A single-file, zero-dependency cron watchdog for Docker Compose: when a container is marked
> `unhealthy`, it force-recreates the service **in dependency order** — self-healing zombie
> containers (e.g. after a provider-forced server reboot) in ~3 minutes.

---

## 为什么需要它（适用场景）

服务器重启是躲不掉的常态：系统更新、云厂商维护、宿主迁移、内核补丁……Docker 守护进程
开机自启、按 `restart` 策略拉起全部容器——但 **Docker 开机拉起不经过 compose 的健康检查**，
应用若卡在"端口已监听、请求管道已死"的**僵尸态**，`docker ps` 看不出异常、
外部探测全超时，直到有人工发现。

这个看门狗补上最后一环：

| 角色 | 职责 |
|------|------|
| **healthcheck**（compose 定义） | **感知**：定期探活，把僵尸标成 `unhealthy` |
| **watchdog.sh + cron**（本项目） | **行动**：发现 `unhealthy` → 按依赖序 `up -d --force-recreate` |
| **外部拨测告警**（如 Uptime Kuma） | **喊人**：自愈万一失败，邮件通知你 |

---

## 特性

- **零配置**：服务名、compose 文件路径、部署目录全部从容器的 **compose 标签**自动读取——
  换服务器、改目录、改 compose 文件名都不用改脚本
- **零依赖**：bash + docker CLI + cron，脚本本体无任何第三方依赖，无守护进程常驻
- **静默设计**：`healthy` 时零输出零日志——"平时安静 = 一切正常"；动作与错误全部带时间戳留痕
- **守卫齐全**：参数校验、标签缺失时明确报错并打印现场值，绝不盲目重建
- **单文件**：一个 `.sh` 拷过去 `chmod +x` 即用

---

## 工作原理

```
容器僵死（如服务器重启后冷启动竞态）
   ↓ healthcheck：每 N 秒探活，连续失败
~2 分钟后 状态 = unhealthy        （建议 start_period 60s + interval 15s + retries 3）
   ↓ cron 每分钟调用 watchdog.sh
≤1 分钟后 脚本读到 unhealthy
   ↓ 从 compose 标签解析：部署目录 / compose 文件 / 服务名
   ↓ docker compose -f <file> up -d --force-recreate <service>
   ↓ up 遵守 depends_on：等依赖服务健康后才重建目标（消除冷启动竞态）
~30 秒 应用恢复 → 状态回 healthy，脚本恢复静默
```

**为什么用 `up -d --force-recreate` 而不是 `restart`**：
`docker compose restart` **绕过 `depends_on` 健康条件**，可能在数据库未就绪时重启应用，
造成二次故障（真实踩坑）；`up -d` 严格按依赖顺序放行。

---

## 要求

- Linux 服务器 + Docker Engine（compose **v2** CLI，即 `docker compose`）
- cron 在运行（`systemctl is-enabled cron` → `enabled`；CentOS 系统名为 `crond`）
- 目标容器由 **`docker compose` 创建**（脚本依赖其标签）
- 目标服务在 compose 里**已配置 healthcheck**（没有它看门狗永不触发）

---

## 快速开始

### 1. 给目标服务加 healthcheck（compose 里追加）

```yaml
  api:
    # ……既有配置……
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/localhost/8080' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 60s
```

> 端口换你的应用内部端口；镜像需带 `bash`（Debian/Ubuntu 系镜像均可；
> Alpine 用 `nc -z localhost <port>` 替代探活命令）。
>
> ⚠️ **healthcheck 变更必须 `up -d --force-recreate <服务>` 才生效，`restart` 不会应用新定义。**

### 2. 部署脚本

```bash
# 拷到服务器（示例路径，任意可执行位置都行）
sudo cp watchdog.sh /usr/local/bin/watchdog.sh
sudo chmod +x /usr/local/bin/watchdog.sh

# 手动验证一次（healthy 时的正确表现 = 无输出、exit 0）
/usr/local/bin/watchdog.sh <你的容器名>; echo "exit=$?"
```

> ⚠️ 从 Windows 传文件后若报 `Permission denied` → `chmod +x`（**每次重传都要补**）；
> 报 `^M: bad interpreter` → 文件是 CRLF，`sed -i 's/\r$//' /usr/local/bin/watchdog.sh`。
> 从本仓库正常检出无此问题（建议仓库根保留 `*.sh text eol=lf` 的 `.gitattributes`）。

### 3. 挂 crontab（见 `examples/crontab`）

```bash
crontab -l 2>/dev/null > /tmp/crontab.bak   # 先备份现有清单
crontab -e
```

粘贴一行（换成你的容器名与路径）：

```
* * * * * /usr/local/bin/watchdog.sh <你的容器名> >> /var/log/<你的容器名>-watchdog.log 2>&1
```

### 4. 验证四连

```bash
crontab -l                                            # 调用行在
/usr/local/bin/watchdog.sh <你的容器名>; echo "exit=$?" # 静默 + 0
docker inspect <你的容器名> --format '{{.State.Health.Status}}'   # healthy
ls -l /var/log/<你的容器名>-watchdog.log 2>/dev/null || echo "日志未生成（没触发过，正常）"
```

**部署完成。**

---

## 配置

| 方式 | 写法 | 说明 |
|------|------|------|
| 位置参数 | `watchdog.sh my-container` | 推荐（crontab 直接带参） |
| 环境变量 | `WATCHDOG_CONTAINER=my-container watchdog.sh` | 兜底，便于包装脚本复用 |

除此之外**无任何配置项**——compose 部署信息运行时自动发现。

---

## 日常运维

| 想做什么 | 命令 |
|---------|------|
| 看它救过命没 | `tail -f /var/log/<容器名>-watchdog.log`（带时间戳；**平时为空 = 没出过事**） |
| 看容器健康态 | `docker inspect <容器名> --format '{{.State.Health.Status}}'` |
| 改逻辑 | 改脚本 → 重新部署 → **`chmod +x` 必补** → crontab 不用动 |
| 卸载 | `crontab -e` 删调用行（备份在 `/tmp/crontab.bak` 可恢复）；healthcheck 建议保留 |

---

## 演习（验证自愈真的会触发）

> 低峰期做；坏探活期间**应用本身照常服务**（探活失败 ≠ 服务停止），仅重建那一刻几秒中断。

```bash
cd <部署目录>
cp <compose文件> /tmp/compose.bak
# 把探活命令临时改成必失败（把 echo… 换成 exit 1 的 sed，按你的 healthcheck 实际命令改）：
sed -i "s@echo > /dev/tcp/localhost/8080@exit 1@" <compose文件>
docker compose -f <compose文件> up -d --force-recreate <服务>     # 带坏探活重建
cp /tmp/compose.bak <compose文件>                                  # 【立刻】恢复原文件（防重建循环！）

# 观察：约 105s 变 unhealthy → ≤1 分钟看门狗自动救 → 回到 healthy
watch -n 10 "docker inspect <容器名> --format '{{.State.Health.Status}}'"
tail -f /var/log/<容器名>-watchdog.log
```

验收：状态回 `healthy` + 日志新增两条带时间戳记录 + compose 里探活命令为原版（无残留）。
**若第 3 步恢复没跟上导致反复重建**：手动 `cp /tmp/compose.bak <compose文件>` 再
`up -d --force-recreate <服务>` 即脱困。

> 🚫 **纠错提醒**：网上流传的 `docker update --health-cmd ...` **不存在该参数**
> （健康检查创建后不可变），请勿使用——compose 换坏探活法是唯一可靠的演习手段。

---

## 排障表

| 症状 | 原因 | 处置 |
|------|------|------|
| 日志 `Permission denied` | 传输后丢了执行位（Windows scp 无执行位概念） | `chmod +x`（**每次重传都补**） |
| 日志 `^M` / `bad interpreter` | 脚本是 CRLF | `sed -i 's/\r$//' <脚本路径>`；根治 = 仓库加 `*.sh text eol=lf` |
| 用法报错 exit 2 | 没传容器名 | `watchdog.sh <容器名>` 或设 `WATCHDOG_CONTAINER` |
| `✗ 无法读取 compose 标签` | 容器不是 `docker compose` 创建（手工 `docker run` 无标签） | 核对：`docker inspect <容器名> --format '{{json .Config.Labels}}'`；用 compose 重建该容器 |
| 状态恒为空 / `<no value>` | 没配 healthcheck 或改了没重建 | compose 加 healthcheck 后 **`up -d --force-recreate`**（restart 无效） |
| 反复重建（循环） | 演习时恢复 compose 不及时 | 手动恢复 compose 文件 + `up -d --force-recreate` |
| crontab 没生效 | 行没保存 / cron 服务没起 / 非 root 用户挂载 | `crontab -l`；`systemctl is-enabled cron` |
| 有 unhealthy 但它没救 | 看日志 `exit=` 码；手动跑脚本看报错 | 应急：先手动 `up -d --force-recreate` 恢复业务，再修脚本 |

---

## 红线与最佳实践

1. 生产恢复**一律 `down` + `up -d`**，禁用裸 `docker compose restart`（绕过 depends_on，真实事故根因之一）
2. `down` **绝不带 `-v`**（会删数据卷）
3. 演习时"恢复 compose 文件"必须紧跟"坏探活重建"，否则进入重建循环
4. **没有 healthcheck = 看门狗形同虚设**（状态恒空，永不触发）——部署前必查
5. 建议配合**外部拨测告警**（独立机器）组成三角：感知（healthcheck）→ 自愈（watchdog）→ 喊人（告警）

---

## 目录结构

```
compose-watchdog/
├── README.md            # 本文
├── LICENSE              # MIT
├── watchdog.sh          # 主脚本（唯一运行时文件）
└── examples/
    └── crontab          # crontab 示例行
```

## 开始你自己的仓库

```bash
cd compose-watchdog
git init
# 建议补一个 .gitattributes 防 CRLF：
printf '*.sh text eol=lf\n.gitattributes text eol=lf\n' > .gitattributes
git add . && git commit -m "init: compose-watchdog - healthcheck-driven self-healing for docker compose"
```

## License

MIT © 2026 firstsaofan —— 详见 [LICENSE](LICENSE)。

> 诞生日 2026-10-18：源自一次真实生产事故的自愈方案，经真实事故与人工演习双重验证后抽离泛化，
> 通用适用于任意 Docker Compose 项目，不绑定任何特定部署。
