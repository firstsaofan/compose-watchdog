---
name: compose-watchdog
description: >-
  Single-file, zero-dependency, zero-config self-healing watchdog for
  Docker Compose. Use when a compose container marked unhealthy (e.g.
  zombie state after a provider-forced server reboot) should be
  force-recreated automatically in dependency order, or to deploy,
  validate, drill, or maintain watchdog.sh in any compose project.
  Works for any compose project; needs no API key or credentials.
whenToUse: >-
  User mentions compose watchdog, container self-healing, unhealthy
  container auto recovery, zombie container after server reboot, cron
  watchdog, deploying watchdog.sh, healthcheck-driven recreation, or
  wants a Docker Compose service to recover without human intervention.
---

# compose-watchdog — 通用 Agent 操作手册

> 单文件看门狗：compose healthcheck 把容器标成 `unhealthy` → cron 每分钟调
> `watchdog.sh` → 按依赖序 `docker compose up -d --force-recreate` 重建。
> healthy 时零输出零日志。退出码：0=健康/已处理，1=compose 标签读不到，2=缺参数。
>
> 完整文档在 `README.md`（人读），仓库维护红线在 `AGENTS.md`。**本文件是给 agent 的浓缩版**，
> 只包含"能动什么 / 不能动什么 / 改完怎么验"。

## 一、开始前：向用户要什么（以及不要什么）

**必须**（缺任一就停下来问）：

1. **容器名**——目标服务的容器，且必须由 `docker compose` 创建（脚本读它的标签）
2. 确认该服务在 compose 里**已配 healthcheck**（没有它看门狗永不触发，状态恒空）

**不需要**：任何密钥 / token / API key / 服务器凭据——本脚本只调用**本机 `docker` CLI**，
不联网、不持有凭据。**若用户主动给你密钥，拒绝使用并提醒：本任务用不到。**

## 二、接入四步（详见 README「快速开始」）

1. compose 里给目标服务加 healthcheck（模板与参数见 README；Alpine 用 `nc -z`）
2. `cp watchdog.sh /usr/local/bin/ && chmod +x`（Windows 传文件后**每次都要补 chmod**）
3. crontab 加一行（模板见 `examples/crontab`，含日志重定向）
4. 验证：手动跑一次应**零输出 + exit 0**；`docker inspect` 确认 healthy

## 三、修改脚本后的强制校验（缺一不可，跑完再汇报）

```bash
bash -n watchdog.sh     # 期望 exit=0
bash watchdog.sh        # 期望 stderr 打印用法 + exit=2
shellcheck watchdog.sh  # 本机有才跑；没有不要装，可用镜像：
# docker run --rm -v '<仓库绝对路径>:/src:ro' koalaman/shellcheck:stable /src/watchdog.sh
```

CI（`.github/workflows/ci.yml`）会在 push 时重跑同样四关（bash -n + shellcheck + LF + 缺参守卫）。

## 四、红线（任何一条违反 → 立即停下问用户）

**运行时安全**

- 禁止裸 `docker compose restart`（绕过 `depends_on` 健康条件，真实事故根因）；
  恢复一律 `up -d --force-recreate`，生产恢复用 `down` + `up -d`
- `down` **绝不带 `-v`**（会删数据卷）
- healthcheck 变更必须 `up -d --force-recreate` 才生效（`restart` 不会应用新定义）
- 保持**单文件、零第三方依赖**：不给运行时加包、工具、守护进程

**仓库与凭据**

- `*.sh` 必须 LF；`.gitattributes` 的 `*.sh text eol=lf` 勿删
- **凭据零容忍**：`.env`、`*.pem`、`*.key`、`id_rsa*` 等已被 `.gitignore` 拦截，
  禁止 `git add -f` 绕过；**不读取、不外传任何密钥内容**（对话 / 日志 / 网络请求）；
  示例与文档一律占位符 `<你的容器名>`、`<你的IP>`、`<你的KEY>`，不得出现真实
  服务名 / IP / 域名 / 凭据
- git：禁止 `--force` / `reset` / 改历史 / 未经授权的 push

## 五、演练与排障（触发真实自愈路径时照 README 走）

- 演习：compose 换坏探活 → `up -d --force-recreate` → **立刻恢复原文件**（防重建循环）→
  watch 状态约 105s 变 unhealthy → ≤1 分钟看门狗自动救
- 网传 `docker update --health-cmd` **不存在该参数**（健康检查创建后不可变），勿用
- 排障从 README「排障表」查：先看日志 `exit=` 码，再 `docker inspect` 看状态

## 六、交付前自查

- [ ] `git status` 干净、无凭据文件混入（`.gitignore` 生效）
- [ ] 全部改动文件 UTF-8 无 BOM、`watchdog.sh` 纯 LF、无 U+FFFD
- [ ] 三道本地校验输出原文已附在汇报里
- [ ] 汇报中明确"未新增任何依赖"
