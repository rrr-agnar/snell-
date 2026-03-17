#!/bin/bash
# ==========================================
# 专业级 NFTABLES 转发管理脚本 (多上游+端口冲突检测)
# 支持 SS / 中转场景
# ==========================================

# 修复退格键
stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

# 检查 root
[[ $EUID -ne 0 ]] && echo "错误：请使用 root 用户运行！" && exit 1

# 初始化环境
init_env() {
    if ! command -v nft &> /dev/null; then
        echo "正在安装 nftables..."
        apt update -y && apt install -y nftables -y
    fi

    echo 1 > /proc/sys/net/ipv4/ip_forward
    systemctl enable nftables && systemctl start nftables

    # 创建表和链
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

    # 全局 SNAT / Masquerade
    nft list chain ip nat postrouting | grep -q "masquerade" || \
        nft add rule ip nat postrouting oifname != "lo" masquerade

    # Filter 表
    nft add table inet filter 2>/dev/null
    nft add chain inet filter input { type filter hook input priority 0 \; } 2>/dev/null
    nft list chain inet filter input | grep -q "ct state" || \
        nft add rule inet filter input ct state established,related accept
    nft list chain inet filter input | grep -q "iif lo" || \
        nft add rule inet filter input iif lo accept
    nft list chain inet filter input | grep -q "tcp dport 22" || \
        nft add rule inet filter input tcp dport 22 accept
}

# 检查端口冲突
check_port_conflict() {
    local port=$1
    nft list chain ip nat prerouting 2>/dev/null | grep -q "dport $port" && return 1 || return 0
}

# 添加转发
add_rule() {
    echo -e "\n--- 添加转发 ---"
    read -p "允许来源 IP（可逗号分隔多 IP，如 1.2.3.4,5.6.7.8）: " SRCIPS
    read -p "本地端口 (如 80 或 1000-1100): " LPORT
    read -p "远程落地 IP: " RIP
    read -p "远程端口 (回车则同本地): " RPORT

    [[ -z "$SRCIPS" || -z "$LPORT" || -z "$RIP" ]] && echo "❌ 输入不完整，取消操作" && return
    [[ -z "$RPORT" ]] && TARGET="$RIP" || TARGET="$RIP:$RPORT"

    # 支持逗号多源 IP
    IFS=',' read -ra IPS <<< "$SRCIPS"
    for ip in "${IPS[@]}"; do
        ip=$(echo $ip | xargs)  # 去空格
        # 检查端口冲突
        if ! check_port_conflict $LPORT; then
            echo -e "\033[33m⚠️ 端口 $LPORT 已存在规则，跳过 $ip\033[0m"
            continue
        fi

        nft add rule ip nat prerouting ip saddr $ip tcp dport $LPORT dnat to $TARGET comment "from:$ip"
        nft add rule ip nat prerouting ip saddr $ip udp dport $LPORT dnat to $TARGET comment "from:$ip"
        echo -e "\033[32m✅ 添加: $ip $LPORT → $TARGET\033[0m"
    done

    # 持久化
    nft list ruleset > /etc/nftables.conf
    sleep 1
}

# 查看/删除规则
list_del() {
    while true; do
        clear
        echo "--- 当前转发规则 ---"
        map=$(nft -a list chain ip nat prerouting | grep "dnat")
        [[ -z "$map" ]] && echo "空空如也..." && read -p "按回车返回..." && break

        # 格式化显示
        echo "$map" | sed 's/.*ip saddr \([^ ]*\).*dport \([0-9-]*\).*to \([^ ]*\).*/\1 端口 \2 → \3/' | awk '{print NR ")  " $0}'
        echo "-------------------------------------"
        read -p "输入 ID 删除 (回车返回): " IDX
        [[ -z "$IDX" ]] && break

        target=$(echo "$map" | sed -n "${IDX}p" | awk '{print $0}')
        [[ -n "$target" ]] && \
            nft -a list table ip nat | grep "$target" | awk '{print $NF}' | xargs -n1 nft delete rule ip nat prerouting 2>/dev/null

        nft list ruleset > /etc/nftables.conf
        echo -e "\033[31m✅ 已删除选中规则\033[0m"
        sleep 1
    done
}

# 清空规则（保留 SNAT 和 SSH）
flush_rules() {
    nft flush chain ip nat prerouting
    echo -e "\033[31m✅ 所有转发规则已清空（保留全局 SNAT）\033[0m"
    sleep 1
}

# 主循环
while true; do
    clear
    echo -e "\033[36m=============================="
    echo "    NFTABLES 专业转发管理"
    echo "==============================\033[0m"
    echo " 1. 添加转发规则"
    echo " 2. 查看/删除规则"
    echo " 3. 清空所有转发（保留 SNAT）"
    echo " 4. 退出脚本"
    echo "------------------------------"
    echo -n " 活跃规则数: "
    nft list table ip nat 2>/dev/null | grep -c "dnat" || echo "0"
    echo -e "\n------------------------------"
    read -p "请选择 [1-4]: " OPT

    case $OPT in
        1) init_env && add_rule ;;
        2) list_del ;;
        3) flush_rules ;;
        4) clear && exit 0 ;;
        *) echo "无效选项..." && sleep 1 ;;
    esac
done
