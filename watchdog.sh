#!/bin/bash
# =============================================================================
# compose-watchdog —— 基于 healthcheck 的 Docker Compose 服务看门狗
# =============================================================================
# 作用  ：由 cron 每分钟调用；检查目标容器健康状态，一旦 unhealthy（典型：
#         服务器被厂商重启后应用卡成“端口监听但不响应”的僵尸态），按依赖序重建。
# 原理  ：docker compose up -d --force-recreate <服务> —— up 遵守 depends_on，
#         等依赖服务健康后才动目标（⚠️ 不要用 docker compose restart，它绕过
#         depends_on 健康条件，会造成冷启动竞态）。
# 设计  ：服务名 / compose 文件 / 部署目录全部从容器的 compose 标签自动读取，
#         零配置——换服务器、改目录、改 compose 文件名都不用改本脚本。
# 输出  ：healthy 时完全静默（无输出）；动作与错误全部走 stdout/stderr，
#         由 crontab 的重定向统一落日志（每条带时间戳）。
#
# 用法  ：watchdog.sh <容器名>
#         或：WATCHDOG_CONTAINER=<容器名> watchdog.sh
#
# 示例  ：
#   ./watchdog.sh <容器名>
#   crontab -e 加入：
#   * * * * * /usr/local/bin/watchdog.sh <容器名> >> /var/log/<容器名>-watchdog.log 2>&1
#
# 前提  ：目标容器①由 docker compose 创建（读标签）②compose 已配 healthcheck
#         （否则健康状态恒为空，永不触发——不报错但也不保护）
# 依赖  ：bash、docker CLI（compose v2）、cron；脚本本身零第三方依赖
# 许可  ：MIT（见 LICENSE）
# =============================================================================
set -u

# ---------- 参数解析（位置参数优先，环境变量兜底） ----------
CONTAINER="${1:-${WATCHDOG_CONTAINER:-}}"
if [ -z "$CONTAINER" ]; then
    echo "用法: $0 <容器名>" >&2
    echo "  或: WATCHDOG_CONTAINER=<容器名> $0" >&2
    echo "前提: 容器由 docker compose 创建且 compose 已配置 healthcheck" >&2
    exit 2
fi

# ---------- 读取健康状态（healthy/pending/空 → 静默退出） ----------
STATUS=$(docker inspect "$CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || true)

if [ "$STATUS" != "unhealthy" ]; then
    exit 0
fi

# ---------- 判定 unhealthy：按依赖序重建 ----------
echo "[$(date '+%F %T %Z')] 检测到 ${CONTAINER}=unhealthy，开始按依赖序重建..."

# 从容器的 compose 标签自动读取部署信息（docker compose 创建的容器必有这些标签）
WORKING_DIR=$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)
SERVICE=$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)
CONFIG_FILES=$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)
COMPOSE_FILE=${CONFIG_FILES%%,*}        # 多文件场景（-f a.yml -f b.yml）取第一个

if [ -z "$WORKING_DIR" ] || [ -z "$SERVICE" ] || [ -z "$COMPOSE_FILE" ]; then
    echo "[$(date '+%F %T %Z')] ✗ 无法读取 compose 标签，放弃重建（容器不是 docker compose 创建的？）"
    echo "    working_dir='${WORKING_DIR}' service='${SERVICE}' config_files='${COMPOSE_FILE}'"
    exit 1
fi

case "$COMPOSE_FILE" in
    /*) FULL_FILE="$COMPOSE_FILE" ;;                 # 绝对路径直接用
    *)  FULL_FILE="$WORKING_DIR/$COMPOSE_FILE" ;;    # 相对路径拼部署目录
esac

echo "[$(date '+%F %T %Z')] compose=${FULL_FILE} service=${SERVICE}"
docker compose -f "$FULL_FILE" up -d --force-recreate "$SERVICE"
echo "[$(date '+%F %T %Z')] 重建结束，exit=$?"
