# Docker 节点稳定性指南

## 问题诊断

如果 Docker 节点过一段时间就死掉了，请按以下步骤诊断和解决。

---

## 一、常见原因分析

### 1.1 已修复的历史问题

✅ **13小时节点冻结** - 已修复 (2025-04)
- **原因**: P2P socket 无超时，半开连接阻塞 `writeAll()`
- **修复**: 添加 `SO_RCVTIMEO` / `SO_SNDTIMEO` (100ms)

✅ **双重释放内存破坏** - 已修复 (2025-04)
- **原因**: `PeerConnection.deinit()` 和所有者都调用 `destroy()`
- **修复**: 移除自毁，所有权归 `P2PServer`

---

## 二、诊断步骤

### 2.1 检查容器状态

```bash
# 查看所有容器状态
docker ps -a --filter "name=zknot3"

# 查看重启次数
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  echo "$c: $(docker inspect --format='{{.RestartCount}}' $c) restarts"
done
```

### 2.2 查看日志

```bash
# 查看特定节点日志
docker logs zknot3-validator-1 --tail 100

# 搜索错误
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  echo "=== $c ==="
  docker logs $c 2>&1 | grep -i "error\|panic\|double free\|gpa" | tail -20
done

# 搜索特定错误
docker logs zknot3-validator-1 2>&1 | grep -c "double free"
docker logs zknot3-validator-1 2>&1 | grep -c "error(gpa)"
```

### 2.3 检查资源使用

```bash
# 查看容器资源使用
docker stats zknot3-validator-1 --no-stream

# 查看所有容器资源
docker stats --no-stream --filter "name=zknot3"
```

---

## 三、解决方案

### 3.1 确保使用最新版本

```bash
# 重新构建镜像
cd deploy/docker
docker build -t zknot3:latest -f Dockerfile ../..

# 重启容器
docker compose down
docker compose up -d
```

### 3.2 配置 Docker 自动重启

`docker-compose.yml` 已配置 `restart: unless-stopped`，但可以增强：

```yaml
services:
  zknot3-validator-1:
    restart: always  # 改为 always
    # 添加健康检查
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### 3.3 增加资源限制

```yaml
services:
  zknot3-validator-1:
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
        reservations:
          cpus: '0.5'
          memory: 1G
```

### 3.4 使用监控工具

```bash
# 使用项目提供的浸泡监控
./tools/soak_monitor.sh 1  # 测试1小时

# 或持续监控
./tools/soak_monitor.sh
```

---

## 四、长期运行最佳实践

### 4.1 日志轮转

配置 Docker 日志驱动：

```yaml
services:
  zknot3-validator-1:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

### 4.2 数据持久化

确保数据卷正确配置：

```yaml
volumes:
  zknot3-data-1:
    driver: local
```

### 4.3 定期健康检查

创建定时任务：

```bash
#!/bin/bash
# check_nodes.sh
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  if ! docker ps --filter "name=$c" --filter "status=running" | grep -q $c; then
    echo "⚠️  $c 不在运行，正在重启..."
    docker start $c
  fi
done
```

---

## 五、快速修复命令

```bash
# 一键重启所有节点
cd deploy/docker
docker compose restart

# 完全重置（慎用！会删除数据）
docker compose down -v
docker compose up -d

# 仅重启问题节点
docker restart zknot3-validator-1

# 查看实时日志
docker logs -f zknot3-validator-1
```

---

## 六、联系支持

如果问题持续存在，请提供：
1. `docker logs` 输出
2. `docker ps -a` 输出
3. `docker stats` 输出
4. 配置文件内容
