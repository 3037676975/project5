#!/bin/bash

# Project5 自动部署脚本
# 用于宝塔 Git 自动部署调用
# Kokoro-82M-v1.1-zh TTS Service

set -e

PROJECT_DIR="/www/wwwroot/project5"

cd "$PROJECT_DIR"

echo "====================================="
echo "Project5 Auto Deploy"
echo "Kokoro TTS Service"
echo "====================================="

# 拉取最新代码
echo "[1/5] Pull latest code"
git pull origin main

# 创建必要目录
mkdir -p models
mkdir -p outputs
mkdir -p logs

# 如果存在 docker-compose 则自动重启服务
if [ -f "docker-compose.yml" ]; then
    echo "[2/5] Restart docker services"
    docker compose pull || true
    docker compose up -d --build
else
    echo "[2/5] docker-compose.yml not found, skip docker deploy"
fi

# Python 服务自动更新
if [ -f "requirements.txt" ]; then
    echo "[3/5] Install python dependencies"
    pip3 install -r requirements.txt
fi

# 检查服务状态
if [ -f "docker-compose.yml" ]; then
    echo "[4/5] Container status"
    docker compose ps
fi

# 写入部署时间
DATE=$(date '+%Y-%m-%d %H:%M:%S')
echo "Deploy success: $DATE" >> deploy.log

echo "[5/5] Deploy finished"
echo "====================================="
