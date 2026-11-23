# fingerprint-chromium 150 · Linux 容器方案（macOS arm64 实测可用）

macOS 官方预编译停在 148；150 只有 Linux/Windows 构建。在 Apple Silicon 上用
Docker + Rosetta 跑 x86_64 Linux 版，实测可拿到 **Chrome/150 + 完整 GPU 元数据伪造**
（macOS 版缺的正是 GPU 那一段）。

## 一次性准备

```bash
mkdir -p ~/fp150 && cd ~/fp150
curl -LO https://github.com/adryfish/fingerprint-chromium/releases/download/150.0.7871.186/ungoogled-chromium-150.0.7871.186-1-x86_64_linux.tar.xz
tar -xf ungoogled-chromium-150.0.7871.186-1-x86_64_linux.tar.xz
# 把本目录的 Dockerfile / entry.sh 放进来，tree/ 保持解包后的目录名
docker build --platform linux/amd64 -t fp150:latest .
```

Docker Desktop 需开启 **Settings → General → “Use Rosetta for x86_64/amd64 emulation”**。

## 启动

```bash
docker run -d --name fp150 --platform linux/amd64 \
  -p 127.0.0.1:9334:9334 \
  -e FP_SEED=5001 -e TZ=Asia/Tokyo -e FP_LANG=ja-JP \
  -v ~/fp150/data:/data fp150:latest

curl -s http://127.0.0.1:9334/json/version      # Chrome/150.0.7871.186
```

## 接入农场

```bash
node farm.js attach --account l150 --cdp http://127.0.0.1:9334 \
  --engine linux150 --tz Asia/Tokyo --lang ja-JP --seed 5001
node farm.js check --account l150
node driver.js --cdp http://127.0.0.1:9334 scan
```

## 两个必须知道的细节

| 现象 | 原因 | 处理 |
|---|---|---|
| 宿主 curl 9333 连不上 | Chrome 只监听容器内 `127.0.0.1`，忽略 `--remote-debugging-address` | entry.sh 里用 `socat` 把 9333 转到 `0.0.0.0:9334`，映射 9334 |
| WebGL 为 null | 容器无 GPU | `--use-angle=swiftshader --enable-unsafe-swiftshader` + `--fingerprint-gpu-vendor/-renderer`，对外报出的是伪造的 NVIDIA 串 |

## 性能

x86_64 经 Rosetta 执行：启动 ~8 s，单实例内存 ~600–900 MB。**适合验证与小批量，不适合单机开 10 个**；
上量请换真 x86 Linux 机器。
