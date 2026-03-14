#!/bin/bash
# 修复退格键
stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

[[ $EUID -ne 0 ]] && echo "需 root 权限" && exit 1

init_env() {
    if ! command -v nft &> /dev/null; then 
        echo "正在安装依赖..."
        apt update -y && apt install -y nftables
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward
    systemctl enable nftables && systemctl start nftables
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
}

add_rule() {
    read -p "本地端口: " LPORT
    read -p "远程 IP: " RIP
    read -p "远程端口: " RPORT
    nft add rule ip nat prerouting tcp dport $LPORT counter dnat to $RIP:$RPORT
    nft add rule ip nat prerouting udp dport $LPORT counter dnat to $RIP:$RPORT
    nft add rule ip nat postrouting ip daddr $RIP tcp dport $RPORT counter masquerade
    nft add rule ip nat postrouting ip daddr $RIP udp dport $RPORT counter masquerade
    nft list ruleset > /etc/nftables.conf
    echo -e "\n\033[32m✅ 已添加: $LPORT -> $RIP:$RPORT\033[0m"
    sleep 1
}

list_del() {
    clear
    echo -e "--- 当前转发列表 ---"
    local map=$(nft -a list table ip nat | grep "dnat")
    if [ -z "$map" ]; then
        echo "空空如也..."
        read -p "按回车返回..."
        return
    fi
    echo "$map" | sed 's/.*dport \([0-9]*\).*to \([^ ]*\).*/\1 -> \2/' | awk '{print NR ")  " $0}'
    echo "--------------------"
    read -p "输入 ID 删除 (回车返回): " IDX
    [ -z "$IDX" ] && return

    local target_port=$(echo "$map" | sed -n "${IDX}p" | sed 's/.*dport \([0-9]*\).*/\1/')
    if [ ! -z "$target_port" ]; then
        nft -a list table ip nat | grep "dport $target_port" | awk '{print $NF}' | while read -r h; do
            nft delete rule ip nat prerouting handle $h 2>/dev/null
            nft delete rule ip nat postrouting handle $h 2>/dev/null
        done
        nft list ruleset > /etc/nftables.conf
        echo -e "\033[31m✅ 端口 $target_port 已清除\033[0m"
        sleep 1
    fi
}

while true; do
    clear
    echo -e "\033[36m=== NFT 转发管理 (内核级) ===\033[0m"
    echo "1. 添加转发"
    echo "2. 查看/删除"
    echo "3. 清空所有"
    echo "4. 退出"
    echo "------------------------------"
    echo -n "当前转发数: "
    nft list table ip nat 2>/dev/null | grep -c "dnat" || echo "0"
    echo "------------------------------"
    read -p "选择 [1-4]: " OPT
    case $OPT in
        1) init_env && add_rule ;;
        2) list_del ;;
        3) nft flush ruleset && echo "已清空" && sleep 1 ;;
        4) clear && exit 0 ;;
        *) echo "无效选项" && sleep 1 ;;
    esac
done
