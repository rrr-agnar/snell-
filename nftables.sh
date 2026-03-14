#!/bin/bash
# ==========================================
# NFTABLES 增强版一键转发脚本 (支持范围转发)
# ==========================================

# 修复退格键显示 ^H 问题
stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo "错误：请使用 root 用户运行！" && exit 1

# 初始化内核转发和基础表
init_env() {
    echo "正在初始化环境..."
    if ! command -v nft &> /dev/null; then
        apt update -y && apt install -y nftables
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward
    systemctl enable nftables && systemctl start nftables
    
    # 创建 nat 表和链 (如果已存在则跳过)
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
}

# 添加规则逻辑
add_rule() {
    echo -e "\n--- 添加转发 ---"
    read -p "请输入本地端口 (例如 80 或 100-200): " LPORT
    read -p "请输入远程落地 IP: " RIP
    read -p "请输入远程端口 (范围转发请保持与本地一致，直接回车): " RPORT

    if [[ $LPORT == *"-"* ]]; then
        # 范围转发
        nft add rule ip nat prerouting tcp dport $LPORT counter dnat to $RIP
        nft add rule ip nat prerouting udp dport $LPORT counter dnat to $RIP
        echo -e "\033[32m✅ 已添加范围转发: $LPORT -> $RIP (端口一一对应)\033[0m"
    else
        # 单端口转发
        [[ -z "$RPORT" ] ] && RPORT=$LPORT
        nft add rule ip nat prerouting tcp dport $LPORT counter dnat to $RIP:$RPORT
        nft add rule ip nat prerouting udp dport $LPORT counter dnat to $RIP:$RPORT
        echo -e "\033[32m✅ 已添加单口转发: $LPORT -> $RIP:$RPORT\033[0m"
    fi

    # 通用 SNAT 规则 (Masquerade)
    nft add rule ip nat postrouting ip daddr $RIP counter masquerade
    
    # 保存规则
    nft list ruleset > /etc/nftables.conf
    sleep 2
}

# 查看和删除逻辑
list_del() {
    while true; do
        clear
        echo "--- 当前转发列表 ---"
        # 提取 prerouting 链中的 dnat 规则并带上 handle 编号
        local map=$(nft -a list chain ip nat prerouting | grep "dnat")
        if [[ -z "$map" ]]; then
            echo "当前没有转发规则。"
            read -p "按回车返回主菜单..." 
            break
        fi
        
        echo "$map" | sed 's/.*dport \([0-9-]*\).*to \([^ ]*\).*/\1 -> \2/' | awk '{print NR ")  " $0}'
        echo "-------------------------------------"
        read -p "请输入要删除的 ID (输入 q 返回): " IDX
        [[ "$IDX" == "q" ]] && break
        
        # 获取对应行的端口和 handle
        local target_port=$(echo "$map" | sed -n "${IDX}p" | sed 's/.*dport \([0-9-]*\).*/\1/')
        
        if [[ -n "$target_port" ]]; then
            # 删除相关的 prerouting 和 postrouting 规则 (基于端口匹配删除相关 handle)
            nft -a list table ip nat | grep "dport $target_port" | awk '{print $NF}' | xargs -n1 nft delete rule ip nat prerouting handle 2>/dev/null
            nft -a list table ip nat | grep "daddr" | grep "$target_port" | awk '{print $NF}' | xargs -n1 nft delete rule ip nat postrouting handle 2>/dev/null
            
            nft list ruleset > /etc/nftables.conf
            echo -e "\033[31m✅ 转发 $target_port 已删除\033[0m"
            sleep 1
        else
            echo "输入无效，请重试。"
            sleep 1
        fi
    done
}

# 主菜单循环
while true; do
    clear
    echo -e "\033[36m=============================="
    echo "    NFTABLES 增强管理脚本"
    echo "==============================\033[0m"
    echo " 1. 添加规则 (支持单口或范围)"
    echo " 2. 查看/删除规则"
    echo " 3. 清空所有转发"
    echo " 4. 退出脚本"
    echo "------------------------------"
    echo -n " 状态预览: 当前共有 $(nft list table ip nat 2>/dev/null | grep -c "dnat") 条规则"
    echo -e "\n------------------------------"
    read -p "请选择 [1-4]: " OPT

    case $OPT in
        1) init_env && add_rule ;;
        2) list_del ;;
        3) nft flush ruleset && nft list ruleset > /etc/nftables.conf && echo "已清空所有规则" && sleep 1 ;;
        4) clear && exit 0 ;;
        *) echo "无效选项..." && sleep 1 ;;
    esac
done
