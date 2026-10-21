# Docker node stability

If a container dies after it has been up for a while, start here.

## Fixes already in the tree

**13-hour freeze** (2025-04). P2P sockets had no timeout, so a half-open connection blocked `writeAll()`. `SO_RCVTIMEO` / `SO_SNDTIMEO` are 100ms.

**Double free** (2025-04). `PeerConnection.deinit()` and the owner both called `destroy()`. `deinit()` no longer frees the object. `P2PServer` owns it.

## Check the containers

```bash
docker ps -a --filter "name=zknot3"

for c in zknot3-validator-{1..4} zknot3-fullnode; do
  echo "$c: $(docker inspect --format='{{.RestartCount}}' $c) restarts"
done
```

```bash
docker logs zknot3-validator-1 --tail 100

for c in zknot3-validator-{1..4} zknot3-fullnode; do
  echo "=== $c ==="
  docker logs $c 2>&1 | grep -i "error\|panic\|double free\|gpa" | tail -20
done

docker logs zknot3-validator-1 2>&1 | grep -c "double free"
docker logs zknot3-validator-1 2>&1 | grep -c "error(gpa)"
```

```bash
docker stats zknot3-validator-1 --no-stream
docker stats --no-stream --filter "name=zknot3"
```

## Restart from a current image

```bash
cd deploy/docker
docker build -t zknot3:latest -f Dockerfile ../..
docker compose down
docker compose up -d
```

`docker-compose.yml` uses `restart: unless-stopped`. A health check looks like this:

```yaml
services:
  zknot3-validator-1:
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9003/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

Resource caps:

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

Soak monitor, one hour or until stopped:

```bash
./tools/soak_monitor.sh 1
./tools/soak_monitor.sh
```

## Logs, disk, and a restart loop

```yaml
services:
  zknot3-validator-1:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

```yaml
volumes:
  zknot3-data-1:
    driver: local
```

```bash
#!/bin/bash
for c in zknot3-validator-{1..4} zknot3-fullnode; do
  if ! docker ps --filter "name=$c" --filter "status=running" | grep -q $c; then
    echo "$c is not running, starting it"
    docker start $c
  fi
done
```

```bash
cd deploy/docker
docker compose restart

# deletes volumes
docker compose down -v
docker compose up -d

docker restart zknot3-validator-1
docker logs -f zknot3-validator-1
```
