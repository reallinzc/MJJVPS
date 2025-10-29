#!/usr/bin/env bash
# relay_optional_snat.sh — nftables relay with per-rule optional SNAT (IPv4 only)
# 结构与 A 类似，区别：DB 增加 snat 开关与 SNAT 源 IP；渲染时按规则决定是否 POSTROUTING SNAT
set -euo pipefail

# —— 通用辅助函数（与 A 基本一致，省略重复注释） ——
err(){ echo "ERROR: $*" >&2; } ; info(){ echo "[*] $*"; } ; ok(){ echo "[OK] $*"; } ; warn(){ echo "[WARN] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; } ; require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "请以 root 运行"; exit 1; }; }
validate_ipv4(){ local ip=$1; [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; IFS=. read -r a b c d <<<"$ip"; for n in $a $b $c $d; do ((n>=0&&n<=255)) || return 1; done; }
validate_port(){ local p=$1; [[ $p =~ ^[0-9]+$ ]] && ((p>=1&&p<=65535)); }
validate_domain(){ local d=$1; [[ -n $d && ${#d} -le 253 && $d =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && ! $d =~ \.\. && ! $d =~ ^- && ! $d =~ -$ ]]; }
resolve_domain(){ local domain=$1 ip=""; if have getent; then ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NF{print $1; exit}'); fi; if ! validate_ipv4 "${ip:-}"; then if have dig; then ip=$(dig +short A "$domain" 2>/dev/null | awk 'NF{print; exit}'); fi; fi; if ! validate_ipv4 "${ip:-}"; then if have nslookup; then ip=$(nslookup -type=A "$domain" 2>/dev/null | awk '/Address: /{print $2}' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1); fi; fi; validate_ipv4 "${ip:-}" && { echo "$ip"; return 0; } || return 1; }
sysd_available(){ [[ -d /run/systemd/system ]] && have systemctl; }
write_sysctl(){ local f="$1"; shift; mkdir -p /etc/sysctl.d; : >"$f"; for kv in "$@"; do echo "$kv" >>"$f"; done; sysctl -p "$f" >/dev/null 2>&1 || true; }
enable_kernel_forward_pack(){ write_sysctl "/etc/sysctl.d/99-relay-kernel.conf" "net.ipv4.ip_forward=1" "net.ipv4.conf.all.rp_filter=0" "net.ipv4.conf.default.rp_filter=0" "net.ipv4.conf.all.accept_redirects=0" "net.ipv4.conf.default.accept_redirects=0" "net.ipv4.conf.all.send_redirects=0" "net.ipv4.conf.default.send_redirects=0"; ok "已开启转发"; }
compute_ct_max(){ awk '/MemTotal/ {m=$2; exit} END{if(m=="") m=1048576; print (m/8<262144?262144:(m/8>2097152?2097152:m/8)) }' /proc/meminfo; }
tune_conntrack_balanced(){ local max; max=$(compute_ct_max); write_sysctl "/etc/sysctl.d/99-conntrack-relay.conf" "net.netfilter.nf_conntrack_max=${max}" "net.netfilter.nf_conntrack_tcp_timeout_close=10" "net.netfilter.nf_conntrack_tcp_timeout_close_wait=120" "net.netfilter.nf_conntrack_tcp_timeout_fin_wait=120" "net.netfilter.nf_conntrack_tcp_timeout_last_ack=60" "net.netfilter.nf_conntrack_tcp_timeout_syn_recv=60" "net.netfilter.nf_conntrack_tcp_timeout_syn_sent=120" "net.netfilter.nf_conntrack_tcp_timeout_time_wait=120" "net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=300" "net.netfilter.nf_conntrack_tcp_timeout_established=1800" "net.netfilter.nf_conntrack_udp_timeout=60" "net.netfilter.nf_conntrack_udp_timeout_stream=300"; ok "conntrack（均衡）已应用"; }
tune_conntrack_aggressive(){ local max; max=$(compute_ct_max); write_sysctl "/etc/sysctl.d/99-conntrack-relay.conf" "net.netfilter.nf_conntrack_max=${max}" "net.netfilter.nf_conntrack_tcp_timeout_close=5" "net.netfilter.nf_conntrack_tcp_timeout_close_wait=30" "net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30" "net.netfilter.nf_conntrack_tcp_timeout_last_ack=15" "net.netfilter.nf_conntrack_tcp_timeout_syn_recv=20" "net.netfilter.nf_conntrack_tcp_timeout_syn_sent=20" "net.netfilter.nf_conntrack_tcp_timeout_time_wait=15" "net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=60" "net.netfilter.nf_conntrack_tcp_timeout_established=300" "net.netfilter.nf_conntrack_udp_timeout=10" "net.netfilter.nf_conntrack_udp_timeout_stream=60"; ok "conntrack（激进）已应用"; }
persist_rules_with_systemd(){ local rf="$1" svc=/etc/systemd/system/relay-rules.service; cat >"$svc"<<EOF
[Unit] Description=Load relay_nat rules
After=network-online.target
Wants=network-online.target
[Service] Type=oneshot
ExecStart=/usr/bin/env nft -f $rf
RemainAfterExit=yes
[Install] WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now relay-rules.service; ok "已持久化并加载规则"; }
install_guard_timer(){ local svc=/etc/systemd/system/relay-rules-guard.service; local tim=/etc/systemd/system/relay-rules-guard.timer; local self; self="$(realpath "$0" 2>/dev/null || echo "$0")"; cat >"$svc"<<EOF
[Unit] Description=Guard: reload relay rules & update domain IPs
[Service] Type=oneshot
ExecStart=/bin/sh -c 'bash "$self" --guard-check'
EOF
  cat >"$tim"<<'EOF'
[Unit] Description=Guard timer for relay_nat
[Timer] OnUnitActiveSec=1min
AccuracySec=15s
Unit=relay-rules-guard.service
[Install] WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now relay-rules-guard.timer; ok "已安装守护 timer"; }
disable_guard_timer(){ systemctl disable --now relay-rules-guard.timer 2>/dev/null || true; rm -f /etc/systemd/system/relay-rules-guard.{service,timer}; systemctl daemon-reload || true; ok "已移除守护 timer"; }

# —— 状态 & 渲染 ——
RULES_FILE=/etc/relay-rules.nft
RULES_DB=/etc/relay-rules.db   # 行格式：lport rport rip snat[0/1] lip selftest[0/1] [domain]

render_rules(){
  {
    echo "table ip relay_nat {"
    echo "  chain PREROUTING { type nat hook prerouting priority -100; policy accept; }"
    echo "  chain POSTROUTING { type nat hook postrouting priority 100; policy accept; }"
    echo "  chain OUTPUT      { type nat hook output      priority -100; policy accept; }"
    echo "}"
    [[ -s $RULES_DB ]] && while read -r lport rport rip snat lip selftest domain; do
      [[ -z "${lport:-}" || "$lport" =~ ^# ]] && continue
      echo "add rule ip relay_nat PREROUTING tcp dport $lport counter dnat to $rip:$rport"
      echo "add rule ip relay_nat PREROUTING udp dport $lport counter dnat to $rip:$rport"
      if [[ "${snat:-0}" == "1" ]]; then
        echo "add rule ip relay_nat POSTROUTING ip daddr $rip tcp dport $rport counter snat to $lip"
        echo "add rule ip relay_nat POSTROUTING ip daddr $rip udp dport $rport counter snat to $lip"
      fi
      if [[ "${selftest:-0}" == "1" ]]; then
        echo "add rule ip relay_nat OUTPUT ip daddr 127.0.0.1 tcp dport $lport counter dnat to $rip:$rport"
        echo "add rule ip relay_nat OUTPUT ip daddr 127.0.0.1 udp dport $lport counter dnat to $rip:$rport"
      fi
    done <"$RULES_DB"
  } >"$RULES_FILE"
  nft delete table ip relay_nat 2>/dev/null || true
  nft -f "$RULES_FILE"
  ok "已渲染并应用规则（含可选 SNAT）"
}

add_rule(){
  local lport="$1" rport="$2" rip="$3" snat="$4" lip="$5" selftest="$6" domain="${7:-}"
  mkdir -p "$(dirname "$RULES_DB")"; touch "$RULES_DB"
  local tmp; tmp=$(mktemp)
  awk -v l="$lport" -v r="$rport" -v ip="$rip" '!(NF>=6 && $1==l && $2==r && $3==ip){print $0}' "$RULES_DB" >"$tmp"
  mv "$tmp" "$RULES_DB"
  if [[ -n "$domain" ]]; then
    echo "$lport $rport $rip $snat $lip $selftest $domain" >>"$RULES_DB"
    ok "已添加/更新: $lport -> $domain($rip):$rport SNAT=$snat($lip) selftest=$selftest"
  else
    echo "$lport $rport $rip $snat $lip $selftest" >>"$RULES_DB"
    ok "已添加/更新: $lport -> $rip:$rport SNAT=$snat($lip) selftest=$selftest"
  fi
  render_rules
}

list_rules(){
  if ! awk 'NF>=6{found=1; exit} END{exit !found}' "$RULES_DB" 2>/dev/null; then
    echo "（当前无转发项）"; return 1; fi
  printf "%-4s %-8s %-22s %-6s %-16s %-8s %-15s\n" "#" "LPORT" "REMOTE" "SNAT" "LIP" "SELF" "DOMAIN"
  nl -w2 -s' ' "$RULES_DB" | while read -r idx lport rport rip snat lip self domain; do
    [[ -z "${idx:-}" || -z "${rip:-}" ]] && continue
    printf "%-4s %-8s %-22s %-6s %-16s %-8s %-15s\n" "$idx" "$lport" "$rip:$rport" "$([[ $snat == 1 ]] && echo yes || echo no)" "$lip" "$([[ $self == 1 ]] && echo yes || echo no)" "${domain:-}"
  done
}

delete_by_indices(){
  local idxs="$1"; [[ -z $idxs ]] && { warn "未提供编号"; return 1; }
  local tmp; tmp=$(mktemp)
  awk -v del="$(echo "$idxs" | tr ',' ' ')" 'BEGIN{split(del,a," "); for(i in a) if(a[i]~/^[0-9]+$/) D[a[i]]=1} {row++; if(!D[row]) print $0}' "$RULES_DB" >"$tmp"
  mv "$tmp" "$RULES_DB"; render_rules; ok "已按编号删除并重载"
}

clear_all(){ : >"$RULES_DB"; render_rules; ok "已清空所有转发项"; }

update_domain_ips(){
  [[ -s $RULES_DB ]] || return 0
  local tmp; tmp=$(mktemp); local updated=0
  while read -r lport rport rip snat lip self domain; do
    [[ -z ${lport:-} || "$lport" =~ ^# ]] && { echo "$lport $rport $rip $snat $lip $self $domain" >>"$tmp"; continue; }
    [[ -z ${domain:-} ]] && { echo "$lport $rport $rip $snat $lip $self" >>"$tmp"; continue; }
    local new; new="$(resolve_domain "$domain" 2>/dev/null || echo "$rip")"
    if [[ "$new" != "$rip" && -n "$new" ]]; then
      echo "$lport $rport $new $snat $lip $self $domain" >>"$tmp"; updated=$((updated+1)); info "域名 $domain 更新: $rip -> $new"
    else
      echo "$lport $rport $rip $snat $lip $self $domain" >>"$tmp"
    fi
  done <"$RULES_DB"
  mv "$tmp" "$RULES_DB"; ((updated>0)) && { render_rules; ok "已更新 $updated 个域名 IP"; }
}

guard_check(){ nft list table ip relay_nat >/dev/null 2>&1 || nft -f "$RULES_FILE" 2>/dev/null || true; update_domain_ips >/dev/null 2>&1 || true; }

menu_oneclick(){
  echo; echo "== 一键：开启转发 + conntrack 调优 =="
  enable_kernel_forward_pack
  read -rp "选择 conntrack 模式 1) 均衡(默认) 2) 激进 : " m; m="${m:-1}"
  [[ "$m" == "2" ]] && tune_conntrack_aggressive || tune_conntrack_balanced
  if sysd_available; then read -rp "安装守护 timer（每分钟自检）? [Y/n]: " yn; [[ -z "${yn:-}" || "$yn" =~ ^[Yy]$ ]] && install_guard_timer || ok "已跳过守护"; else warn "无 systemd，可用 cron 守护"; fi
}

add_flow(){
  local lport rport target rip domain snat lip self
  while true; do read -rp "本机监听端口: " lport; validate_port "${lport:-}" && break || echo "端口非法"; done
  while true; do read -rp "目标端口: " rport; validate_port "${rport:-}" && break || echo "端口非法"; done
  while true; do
    read -rp "目标地址(IPv4或域名): " target
    if validate_ipv4 "$target"; then rip="$target"; domain=""; break
    elif validate_domain "$target"; then domain="$target"; rip="$(resolve_domain "$domain" || true)"; [[ -n $rip ]] && { info "解析 $domain -> $rip"; break; } || echo "解析失败";
    else echo "无效地址"; fi
  done
  read -rp "启用 SNAT? [Y/n 默认Y]: " yn; [[ -z "${yn:-}" || "$yn" =~ ^[Yy]$ ]] && snat=1 || snat=0
  if [[ $snat -eq 1 ]]; then
    # 自动探测出站源 IP 作为 SNAT 源，允许用户覆盖
    lip="$(ip -4 route get "$rip" 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
    while true; do read -rp "SNAT 源 IP（默认: ${lip:-请填写}）: " ans; lip="${ans:-$lip}"; validate_ipv4 "${lip:-}" && break || echo "IPv4 非法"; done
  else lip="0.0.0.0"; fi
  read -rp "添加 OUTPUT DNAT 以便本机自测? [y/N]: " yn; [[ $yn =~ ^[Yy]$ ]] && self=1 || self=0
  add_rule "$lport" "$rport" "$rip" "$snat" "$lip" "$self" "$domain"
  if sysd_available; then persist_rules_with_systemd "$RULES_FILE"; else nft -f "$RULES_FILE"; fi
}

uninstall_all(){ nft delete table ip relay_nat 2>/dev/null || true; rm -f "$RULES_FILE" "$RULES_DB"; if sysd_available; then systemctl disable --now relay-rules.service 2>/dev/null || true; rm -f /etc/systemd/system/relay-rules.service; fi; disable_guard_timer; ok "已卸载相关表/服务/文件"; }

main_menu(){
  while true; do
    echo
    echo "relay_nat（可选 SNAT）菜单："
    echo " 1) 新增/更新 转发（可选 SNAT）"
    echo " 2) 删除 转发（按编号）"
    echo " 3) 查看 当前转发"
    echo " 4) 清空 全部转发"
    echo " 5) 重新渲染 规则"
    echo " 6) 完全卸载"
    echo " 7) 一键：开启转发 + conntrack 调优 + (可选)守护"
    echo " 8) 关闭守护"
    echo " c) 退出"
    read -rp "选择: " ch
    case "$ch" in
      1) add_flow ;;
      2) list_rules || true; read -rp "编号(可空格/逗号分隔): " ids; delete_by_indices "$ids" ;;
      3) list_rules || true ;;
      4) clear_all ;;
      5) render_rules ;;
      6) uninstall_all ;;
      7) menu_oneclick ;;
      8) disable_guard_timer ;;
      c) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# ---------- entry ----------
if [[ "${1:-}" == "--guard-check" ]]; then guard_check; exit 0; fi
require_root; render_rules; main_menu