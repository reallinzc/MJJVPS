#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 定义 Snell Server 的安装路径
INSTALL_DIR="/usr/local/bin"
SNELL_SERVER="$INSTALL_DIR/snell-server"

# 获取系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_URL="amd64"
        ;;
    i386|i686)
        ARCH_URL="i386"
        ;;
    aarch64|arm64)
        ARCH_URL="aarch64"
        ;;
    armv7l)
        ARCH_URL="armv7l"
        ;;
    *)
        echo -e "${RED}不支持的架构: $ARCH${NC}"
        exit 1
        ;;
esac

# 下载地址
DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.1.0-linux-$ARCH_URL.zip"

# 创建临时目录
TMP_DIR=$(mktemp -d)
cd $TMP_DIR

# 下载最新版本
echo -e "${GREEN}正在下载 Snell Server...${NC}"
if ! wget -q --show-progress $DOWNLOAD_URL; then
    echo -e "${RED}下载失败${NC}"
    exit 1
fi

# 解压文件
echo -e "${GREEN}正在解压...${NC}"
unzip -q snell-server-*.zip

# 停止现有的 Snell Server 服务（如果存在）
if systemctl is-active --quiet snell-server; then
    echo -e "${GREEN}停止 Snell Server 服务...${NC}"
    systemctl stop snell-server
fi

# 替换旧版本
echo -e "${GREEN}替换 Snell Server...${NC}"
mv snell-server $SNELL_SERVER
chmod +x $SNELL_SERVER

# 重启 Snell Server 服务（如果存在）
if systemctl list-unit-files | grep -q snell-server; then
    echo -e "${GREEN}重启 Snell Server 服务...${NC}"
    systemctl start snell-server
fi

# 清理临时文件
cd
rm -rf $TMP_DIR

echo -e "${GREEN}Snell Server 已更新到最新版本${NC}"
echo -e "${GREEN}当前版本信息：${NC}"
$SNELL_SERVER -v

echo -e "${GREEN}更新完成${NC}"
