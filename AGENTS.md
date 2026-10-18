# AGENTS.md — 给 AI 代理的操作说明

## 这是什么

单文件、零依赖的 Docker Compose 看门狗：compose healthcheck 把容器标记为 `unhealthy`
时，由 cron 每分钟调用 `watchdog.sh`，按依赖序 `up -d --force-recreate` 重建；
healthy 时零输出零日志。退出码：0=健康/已处理，1=compose 标签读不到，2=缺参数。

## 文件布局（仓库根 = 本目录）

- `watchdog.sh`        唯一运行时文件（纯 LF；改后必跑下方"强制校验"）
- `examples/crontab`   部署示例行
- `README.md`          人读完整文档（接入步骤 / 演习 / 排障表都在那里）

## 如何给任意 Compose 项目接入（4 步，详见 README"快速开始"）

1. compose 里给目标服务加 healthcheck（没有它，看门狗永不触发）
2. `cp watchdog.sh /usr/local/bin/ && chmod +x` —— 每次重传都要补 chmod
3. crontab 加一行（模板见 `examples/crontab`）
4. 验证：手动跑一次应"零输出 + exit 0"；`docker inspect` 确认 healthy

## 修改脚本后的强制校验（Windows + Docker Desktop 环境）

```bash
docker run --rm -v '<仓库绝对路径>:/src:ro' mcr.microsoft.com/dotnet/sdk:10.0 \
  bash -n /src/watchdog.sh          # 期望 exit=0
docker run --rm -v '<仓库绝对路径>:/src:ro' mcr.microsoft.com/dotnet/sdk:10.0 \
  bash /src/watchdog.sh             # 期望 stderr 打印用法 + exit=2
```

禁止：挂载 `/var/run/docker.sock`、带容器名参数做真实测试、pull 新镜像。

## 红线（对 AI 同样生效）

- 保持单文件、零第三方依赖；不新增任何包、工具、守护进程
- `*.sh` 必须 LF；`.gitattributes` 里的 `*.sh text eol=lf` 规则勿删
- 示例与文档中不得出现真实服务名 / 服务器 IP / 域名 / 凭据，一律用占位符
- 禁止裸 `docker compose restart`（绕过 depends_on 健康条件，真实事故根因之一）
- `down` 绝不带 `-v`（会删数据卷）；healthcheck 变更必须 `up -d --force-recreate` 才生效
- git：禁止 `--force` / `reset` / 改历史 / 未经授权的 push
