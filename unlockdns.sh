#!/bin/bash

# 定义一些常量
WHITELIST_FILE="/etc/iptables_whitelist"
RULES_DIR="/etc/iptables"
RULES_FILE_V4="${RULES_DIR}/rules.v4"
RULES_FILE_V6="${RULES_DIR}/rules.v6"
PORTS=(53 80 443)

# 添加IP到白名单
add_ip_to_whitelist() {
  echo -n "请输入要添加到白名单的IP: "
  read ip
  if ! grep -q "$ip" "$WHITELIST_FILE" 2>/dev/null; then
    echo "$ip" >> "$WHITELIST_FILE"
    echo "IP $ip 已添加到白名单"
  else
    echo "IP $ip 已经在白名单中"
  fi
}

# 清空规则
clear_rules() {
  echo "清空iptables规则..."
  iptables -F INPUT
  > "$WHITELIST_FILE"
  echo "规则已清空"
}

# 查看白名单
view_whitelist() {
  if [ -f "$WHITELIST_FILE" ]; then
    echo "白名单IP地址及对应的规则:"
    while IFS= read -r ip; do
      echo "白名单IP: $ip"
      for PORT in "${PORTS[@]}"; do
        iptables -L INPUT -v -n | grep "$ip.*dpt:$PORT"
      done
    done < "$WHITELIST_FILE"
  else
    echo "白名单为空"
  fi
}

# 删除现有的禁用规则
remove_default_drop_rules() {
  for PORT in "${PORTS[@]}"; do
    iptables -D INPUT -p tcp --dport $PORT -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport $PORT -j DROP 2>/dev/null
  done
}

# 删除现有的白名单规则
remove_whitelist_rules() {
  if [ -f "$WHITELIST_FILE" ]; then
    while IFS= read -r ip; do
      for PORT in "${PORTS[@]}"; do
        iptables -D INPUT -p tcp -s "$ip" --dport $PORT -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp -s "$ip" --dport $PORT -j ACCEPT 2>/dev/null
      done
    done < "$WHITELIST_FILE"
  fi
}

# 添加默认拒绝规则
add_default_drop_rules() {
  remove_default_drop_rules
  for PORT in "${PORTS[@]}"; do
    iptables -A INPUT -p tcp --dport $PORT -j DROP
    iptables -A INPUT -p udp --dport $PORT -j DROP
  done
  echo "已添加默认拒绝规则: 禁止多个端口的TCP和UDP"
}

# 重新添加白名单规则，保证优先级比禁用规则高
reapply_whitelist() {
  remove_whitelist_rules # 删除已有白名单
  remove_default_drop_rules # 删除默认DROP规则
  
  # 添加白名单规则
  if [ -f "$WHITELIST_FILE" ]; then
    while IFS= read -r ip; do
      for PORT in "${PORTS[@]}"; do
        iptables -I INPUT -p tcp -s "$ip" --dport $PORT -j ACCEPT
        iptables -I INPUT -p udp -s "$ip" --dport $PORT -j ACCEPT
      done
    done < "$WHITELIST_FILE"
  fi
  
  add_default_drop_rules # 添加默认拒绝规则
}

# 创建存储规则的目录
create_rules_dir() {
  if [ ! -d "$RULES_DIR" ]; then
    mkdir -p "$RULES_DIR"
    echo "创建目录: $RULES_DIR"
  fi
}

# 保存规则
save_rules() {
  create_rules_dir
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    netfilter-persistent reload
  elif command -v iptables-save >/dev/null 2>&1; then
    iptables-save > "$RULES_FILE_V4"
    ip6tables-save > "$RULES_FILE_V6"
    echo "iptables规则已保存到 ${RULES_FILE_V4} 和 ${RULES_FILE_V6}"
  elif command -v service >/dev/null 2>&1; then
    service iptables save
    service iptables restart
    echo "iptables规则已保存到 /etc/sysconfig/iptables 并重启服务"
  else
    echo "无法保存iptables规则，请手动检查您的系统配置"
  fi
}

# 主菜单
while true; do
  echo
  echo "1. 添加IP到白名单并放行多个端口(53, 80, 443)"
  echo "2. 清空iptables规则和白名单"
  echo "3. 查看白名单及对应规则"
  echo "4. 退出"
  echo -n "请选择一个操作: "
  read choice
  case $choice in
    1)
      add_ip_to_whitelist
      reapply_whitelist
      save_rules
      ;;
    2)
      clear_rules
      save_rules
      ;;
    3)
      view_whitelist
      ;;
    4)
      break
      ;;
    *)
      echo "无效选择，请重新输入"
      ;;
  esac
done

echo "操作完成"
