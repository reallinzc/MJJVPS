#!/usr/bin/env bash
# enable-tfo.sh — 一键启用 TCP Fast Open（含系统级密钥）+ 自检
# 适用：Linux 内核 4.11+（建议 >= 5.10），需要 root
# 自检说明：需要对端/应用启用 TFO；如 curl 支持 --tcp-fastopen，可用 --test <ip> <port> [count]

set -euo pipefail

err(){ echo "ERROR: $*" >&2; exit 1; }
warn(){ echo "[WARN] $*" >&2; }
info(){ echo "[*] $*"; }
ok(){ echo "[OK] $*"; }

require_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "请用 root 运行：sudo bash enable-tfo.sh"; fi
}

have(){ command -v "$1" >/dev/null 2>&1; }

# -------- sysctl helpers --------
write_sysctl_file(){
  local file="$1"; shift
  mkdir -p /etc/sysctl.d
  : > "$file"
  for kv in "$@"; do echo "$kv" >> "$file"; done
  sysctl -p "$file" >/dev/null || true
}

# 读取 /proc/net/netstat 中的 TFO 计数
read_tfo_counters(){
  # 输出：ACTIVE PASSIVE 两列
  if [[ -r /proc/net/netstat ]]; then
    local A P
    A=$(awk '/TCPFastOpenActive/{print $2}' /proc/net/netstat 2>/dev/null | tail -n1)
    P=$(awk '/TCPFastOpenPassive/{print $2}' /proc/net/netstat 2>/dev/null | tail -n1)
    [[ -z "$A" ]] && A=0
    [[ -z "$P" ]] && P=0
    echo "$A $P"
  else
    echo "0 0"
  fi
}

# 生成 16 字节系统级 fastopen key（32 hex）并写入
ensure_tfo_key(){
  local key_file="/proc/sys/net/ipv4/tcp_fastopen_key"
  if [[ -w "$key_file" ]]; then
    local KEY
    KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    echo "$KEY" > "$key_file" 2>/dev/null || true
    echo "$KEY"
  else
    warn "无法写入 $key_file（可能内核过旧或权限受限），跳过设置系统级密钥"
    echo ""
  fi
}

# 自检：可选用 curl 的 --tcp-fastopen 对指定目标发起 N 次连接
self_test(){
  local ip="${1:-
