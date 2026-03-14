#!/bin/bash

# ==========================================
# NFTABLES 简易转发管理脚本 (支持多对一 & 范围)
# ==========================================

# 修复退格键
stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

# 检查权限
[[ $EUID -ne 0 ]] && echo "错误：请使用 root 用户运行！" && exit 1

# 环境初始化
init_env() {
    if ! command -v nft &> /dev/null; then
        echo "正在安装 nftables..."
        apt update -y && apt install -y nftables
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward
    systemctl enable nftables && systemctl start nftables
    
    # 建立 NAT 表和链
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
}

# 添加转发
add_rule() {
    echo -e "\n--- 添加转发 ---"
    read -p "本地端口 (如 80 或 1000-1100): " LPORT
    read -p "远程落地 IP: " RIP
    read -p "远程端口 (回车则同本地): " RPORT

    # 逻辑：输什么就是什么，不输则 1:1
    if [[ -z "$RPORT" ]]; then
        TARGET="$RIP"
        echo -e "\033[32m✅ 对应转发: $LPORT -> $RIP (端口不变)\033[0m"
    else
        TARGET="$RIP:$RPORT"
        echo -e "\033[32m✅ 直接转发: $LPORT -> $RIP:$RPORT\033[0m"
    fi

    # 写入规则
    nft add rule ip nat prerouting tcp dport $LPORT counter dnat to $TARGET
    nft add rule ip nat prerouting udp dport $LPORT counter dnat to $TARGET
    nft add rule ip nat postrouting ip daddr $RIP counter masquerade
    
    # 持久化保存
    nft list ruleset > /etc/nftables.conf
    sleep 1
}

# 查看与删除
list_del() {
    while true; do
        clear
        echo "--- 当前转发列表 ---"
        local map=$(nft -a list chain ip nat prerouting | grep "dnat")
        if [[ -z "$map" ]]; then
            echo "空空如也..."
            read -p "按回车返回主菜单..." 
            break
        fi
        
        # 格式化显示
        echo "$map" | sed 's/.*dport \([0-9-]*\).*to \([^ ]*\).*/\1 -> \2/' | awk '{print NR ")  " $0}'
        echo "-------------------------------------"
        read -p "输入 ID 删除 (直接回车返回): " IDX
        
        # 回车跳出
        [[ -z "$IDX" ]] && break
        
        # 获取 handle 并删除
        local target_port=$(echo "$map" | sed -n "${IDX}p" | sed 's/.*dport \([0-9-]*\).*/\1/')
        if [[ -n "$target_port" ]]; then
            nft -a list table ip nat | grep "dport $target_port" | awk '{print $NF}' | xargs -n1 nft delete rule ip nat prerouting handle 2>/dev/null
            nft list ruleset > /etc/nftables.conf
            echo -e "\033[31m✅ 已删除端口 $target_port 的相关规则\033[0m"
            sleep 1
        else
            echo "无效输入，请重试。"
            sleep 1
        fi
    done
}

# 主循环
while true; do
    clear
    echo -e "\033[36m=============================="
    echo "    NFTABLES 转发管理工具"
    echo "==============================\033[0m"
    echo " 1. 添加转发规则"
    echo " 2. 查看/删除规则"
    echo " 3. 清空所有转发"
    echo " 4. 退出脚本"
    echo "------------------------------"
    echo -n " 活跃规则数: "
    nft list table ip nat 2>/dev/null | grep -c "dnat" || echo "0"
    echo -e "\n------------------------------"
    read -p "请选择 [1-4]: " OPT

    case $OPT in
        1) init_env && add_rule ;;
        2) list_del ;;
        3) nft flush ruleset && echo "✅ 规则已全部清空" && sleep 1 ;;
        4) clear && exit 0 ;;
        *) echo "无效选项..." && sleep 1 ;;
    esac
done
