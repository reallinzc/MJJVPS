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
  local ip="${1:-}"; local port="${2:-}"; local count="${3:-10}"

  echo
  info "TFO 自检："
  local beforeA beforeP afterA afterP
  read beforeA beforeP < <(read_tfo_counters)
  echo "  计数（前）：Active=$beforeA Passive=$beforeP"

  if [[ -n "$ip" && -n "$port" ]]; then
    if have curl && curl --help all 2>/dev/null | grep -q -- '--tcp-fastopen'; then
      info "  使用 curl --tcp-fastopen 触发 $count 次连接：$ip:$port"
      for i in $(seq 1 "$count"); do
        # 尽量短：TCP 建连即断；对端须启用 TFO 才可能增长 Passive
        curl --tcp-fastopen --connect-timeout 1 -m 2 "http://$ip:$port/" -o /dev/null -s || true
      done
    else
      warn "未检测到支持 --tcp-fastopen 的 curl，无法主动触发；仅读取计数。"
      warn "提示：可改用你自己的 ss-rust/HAProxy(开启 TFO) 做流量触发，再回来看计数变化。"
    fi
  else
    info "  未提供 --test 目标，仅读取计数。你可在另一端发起 TFO 流量后再次运行 --check。"
  fi

  read afterA afterP < <(read_tfo_counters)
  echo "  计数（后）：Active=$afterA Passive=$afterP"
  echo "  ΔActive=$((afterA-beforeA))  ΔPassive=$((afterP-beforeP))"
  echo
  echo "说明："
  echo "  - Active 增长：本机作为客户端成功发起 TFO（需应用 setsockopt TCP_FASTOPEN_CONNECT）"
  echo "  - Passive 增长：本机作为服务端成功接受 TFO（需监听端 setsockopt TCP_FASTOPEN）"
  echo "  - 若 Δ=0，多半为路径/对端未启用或中间盒剥离 TCP 选项。"
}

# 一键启用 TFO（client+server）+ blackhole 快回退 + 系统级密钥
enable_tfo(){
  local CONF="/etc/sysctl.d/99-tfo.conf"
  info "写入并加载 $CONF"
  write_sysctl_file "$CONF" \
    "net.ipv4.tcp_fastopen=3" \
    "net.ipv4.tcp_fastopen_blackhole_timeout_sec=1"

  local KEY
  KEY="$(ensure_tfo_key)"
  if [[ -n "$KEY" ]]; then
    # 同步把 key 持久化（可跨重启）
    sed -i '/^net\.ipv4\.tcp_fastopen_key=/d' "$CONF" || true
    echo "net.ipv4.tcp_fastopen_key=$KEY" >> "$CONF"
    sysctl -p "$CONF" >/dev/null || true
    ok "TFO 已启用；系统级密钥(32hex)：$KEY"
  else
    ok "TFO 已启用；系统级密钥未设置（可忽略或更换新内核）"
  fi

  echo
  info "当前内核参数："
  sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true
  [[ -r /proc/sys/net/ipv4/tcp_fastopen_key ]] && cat /proc/sys/net/ipv4/tcp_fastopen_key 2>/dev/null || true
}

# 能力检查（友好输出）
check_cap(){
  echo
  info "环境与能力检查："
  echo "  内核版本: $(uname -r)"
  if have iptables && iptables --version 2>/dev/null | grep -q nf_tables; then
    echo "  Netfilter 后端: nft (iptables-nft)"
  elif have nft; then
    echo "  Netfilter 后端: nft"
  else
    echo "  Netfilter 后端: 传统 iptables 或未知"
  fi
  echo "  tcp_fastopen 当前值: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo N/A)  (3=client+server)"
  [[ -r /proc/sys/net/ipv4/tcp_fastopen_key ]] || warn "无法读取 tcp_fastopen_key（可能内核过旧）"
}

usage(){
  cat <<'USAGE'
用法：
  sudo bash enable-tfo.sh            # 一键启用 TFO（client+server）+ 系统级密钥 + 黑洞快速回退
  sudo bash enable-tfo.sh --check    # 仅查看当前 TFO 能力与计数
  sudo bash enable-tfo.sh --test <ip> <port> [count]
                                     # 自检：对 <ip:port> 触发 count 次连接（默认10）
                                     # 需要 curl 支持 --tcp-fastopen，且对端应用已启用 TFO

说明：
  - 本脚本只负责“内核侧”启用，应用程序仍需 setsockopt(TCP_FASTOPEN / TCP_FASTOPEN_CONNECT)。
  - 多节点/负载均衡场景请在所有节点统一 tcp_fastopen_key。
USAGE
}

main(){
  require_root
  case "${1:-}" in
    --check)
      check_cap
      self_test  # 仅读计数，不触发
      ;;
    --test)
      shift
      local ip="${1:-}"; local port="${2:-}"; local count="${3:-10}"
      [[ -z "$ip" || -z "$port" ]] && err "用法：--test <ip> <port> [count]"
      check_cap
      self_test "$ip" "$port" "$count"
      ;;
    ""|--enable)
      check_cap
      enable_tfo
      # 只读一次计数，用于对照；如需主动触发请用 --test
      self_test
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage; exit 1;;
  esac
}

main "$@"
