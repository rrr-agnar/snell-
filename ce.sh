#!/bin/bash

# ==========================================
# NFTABLES 转发管理工具 - 稳定修复版
# ==========================================

stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1

init_env() {
    if ! command -v nft &> /dev/null; then
        apt update -y && apt install -y nftables
    fi

    echo 1 > /proc/sys/net/ipv4/ip_forward
    systemctl enable nftables && systemctl start nftables

    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

    nft list chain ip nat postrouting | grep -q masquerade || \
        nft add rule ip nat postrouting oifname != "lo" masquerade
}

# 添加规则
add_rule() {
    echo "--- 添加转发 ---"
    read -p "来源IP: " SRCIP
    read -p "本地端口: " LPORT
    read -p "目标IP: " RIP
    read -p "目标端口(回车同端口): " RPORT

    [[ -z "$SRCIP" || -z "$LPORT" || -z "$RIP" ]] && echo "输入不完整" && return

    [[ -z "$RPORT" ]] && TARGET="$RIP" || TARGET="$RIP:$RPORT"

    nft add rule ip nat prerouting ip saddr $SRCIP tcp dport $LPORT dnat to $TARGET 2>/dev/null
    nft add rule ip nat prerouting ip saddr $SRCIP udp dport $LPORT dnat to $TARGET 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo "✅ 添加成功: $SRCIP $LPORT -> $TARGET"
    else
        echo "❌ 添加失败（可能端口已存在）"
    fi

    nft list ruleset > /etc/nftables.conf
}

# 查看删除
list_del() {
    while true; do
        clear
        echo "--- 当前规则 ---"

        nft -a list chain ip nat prerouting | grep dnat | nl

        echo "----------------------"
        read -p "输入编号删除(回车返回): " NUM
        [[ -z "$NUM" ]] && break

        HANDLE=$(nft -a list chain ip nat prerouting | grep dnat | sed -n "${NUM}p" | awk '{print $NF}')

        if [[ -n "$HANDLE" ]]; then
            nft delete rule ip nat prerouting handle $HANDLE
            echo "✅ 删除成功"
        else
            echo "❌ 无效编号"
        fi

        nft list ruleset > /etc/nftables.conf
        sleep 1
    done
}

flush_rules() {
    nft flush chain ip nat prerouting
    echo "✅ 已清空转发规则"
}

while true; do
    clear
    echo "==== NFT 转发管理 ===="
    echo "1. 添加规则"
    echo "2. 查看/删除"
    echo "3. 清空"
    echo "4. 退出"

    read -p "选择: " opt

    case $opt in
        1) init_env && add_rule ;;
        2) list_del ;;
        3) flush_rules ;;
        4) exit ;;
    esac
done
