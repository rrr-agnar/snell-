#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;36m'
NC='\033[0m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'

RULES_FILE="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.conf"
SCRIPT_PATH=$(realpath "$0")

# 检查权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 root 权限运行此脚本${NC}"
    exit 1
fi

# 1. 环境初始化
prepare_system() {
    if [ ! -f "/usr/local/bin/nf" ]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/nf
        chmod +x /usr/local/bin/nf
    fi
    if ! grep -q "net.ipv4.ip_forward = 1" $SYSCTL_CONF; then
        echo "net.ipv4.ip_forward = 1" >> $SYSCTL_CONF
        sysctl -p > /dev/null 2>&1
    fi
    if ! command -v nft &> /dev/null; then
        apt update && apt install -y nftables
        systemctl enable nftables && systemctl start nftables
    fi
}

# 2. 添加规则 (同步添加 TCP 和 UDP，并打上唯一标记)
add_forward_rule() {
    echo -e "${WHITE}请输入转发规则信息：${NC}"
    read -p "目标服务器 IP: " target_ip
    read -p "本地端口: " local_port
    read -p "目标端口: " target_port

    if [[ -z "$target_ip" || -z "$local_port" || -z "$target_port" ]]; then
        echo -e "${RED}错误：输入不能为空${NC}"; return
    fi

    # 唯一标记：以端口号命名的 tag
    local tag="port_${local_port}"

    nft add table ip forward2jp 2>/dev/null
    nft add chain ip forward2jp prerouting { type nat hook prerouting priority dstnat \; } 2>/dev/null
    nft add chain ip forward2jp postrouting { type nat hook postrouting priority srcnat \; } 2>/dev/null

    # 同时添加两条规则，使用相同的 comment
    nft add rule ip forward2jp prerouting tcp dport "${local_port}" dnat to "${target_ip}:${target_port}" comment "$tag"
    nft add rule ip forward2jp prerouting udp dport "${local_port}" dnat to "${target_ip}:${target_port}" comment "$tag"
    
    if ! nft list chain ip forward2jp postrouting | grep -q "masquerade"; then
        nft add rule ip forward2jp postrouting masquerade
    fi

    nft list ruleset > "$RULES_FILE"
    echo -e "${GREEN}✅ 规则已同步添加 (TCP+UDP)${NC}"
}

# 3. 管理/删除/修改规则 (同步处理)
manage_rules() {
    clear
    echo -e "${CYAN}当前转发规则列表：${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    
    # 提取唯一的端口标记 (按 comment 分组)
    local tags=$(nft list table ip forward2jp 2>/dev/null | grep 'comment "port_' | awk -F'comment "' '{print $2}' | tr -d '"' | sort -u)
    
    if [ -z "$tags" ]; then
        echo -e "  ${WHITE}暂无转发规则${NC}"
        echo -e "${BLUE}----------------------------------------------------------------${NC}"
        return
    fi

    # 显示时按 tag 显示（一个 tag 代表一组 TCP/UDP）
    local i=1
    declare -A tag_map
    while read -r tag; do
        # 从该 tag 的规则中提取信息
        local info=$(nft list table ip forward2jp | grep "comment \"$tag\"" | head -n 1)
        local lp=$(echo "$info" | awk '{for(i=1;i<=NF;i++) if($i=="dport") print $(i+1)}')
        local tgt=$(echo "$info" | awk '{for(i=1;i<=NF;i++) if($i=="to") print $(i+1)}')
        
        echo -e "${WHITE}$i.${NC} 本地端口: ${CYAN}%-6s${NC} | 目标: ${CYAN}%-20s${NC} | 协议: [TCP+UDP]" "$lp" "$tgt"
        tag_map[$i]=$tag
        ((i++))
    done <<< "$tags"
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    
    echo -e "选项: [d] 批量删除 | [m] 同步修改 | [回车] 返回"
    read -p "请选择操作: " opt
    read -p "请输入上方列表序号: " idx
    local target_tag=${tag_map[$idx]}

    if [ -z "$target_tag" ]; then echo -e "${RED}无效序号${NC}"; return; fi

    case $opt in
        d)
            # 根据 tag 批量删除
            local handles=$(nft -a list table ip forward2jp | grep "comment \"$target_tag\"" | awk '{print $NF}')
            for h in $handles; do
                nft delete rule ip forward2jp prerouting handle "$h"
            done
            nft list ruleset > "$RULES_FILE"
            echo -e "${GREEN}✅ 该端口的 TCP 和 UDP 规则已全部同步删除${NC}"
            ;;
        m)
            echo -e "${WHITE}请输入新的转发信息：${NC}"
            read -p "新目标 IP: " n_ip
            read -p "新本地端口: " n_lp
            read -p "新目标端口: " n_tp
            
            # 1. 先同步删除旧的
            local handles=$(nft -a list table ip forward2jp | grep "comment \"$target_tag\"" | awk '{print $NF}')
            for h in $handles; do nft delete rule ip forward2jp prerouting handle "$h"; done
            
            # 2. 再同步添加新的
            local n_tag="port_${n_lp}"
            nft add rule ip forward2jp prerouting tcp dport "${n_lp}" dnat to "${n_ip}:${n_tp}" comment "$n_tag"
            nft add rule ip forward2jp prerouting udp dport "${n_lp}" dnat to "${n_ip}:${n_tp}" comment "$n_tag"
            
            nft list ruleset > "$RULES_FILE"
            echo -e "${GREEN}✅ 该转发项已同步更新${NC}"
            ;;
    esac
}

# 4. 彻底卸载
uninstall_all() {
    echo -e "${RED}警告：这将清空所有规则并卸载 nftables！${NC}"
    read -p "确认完全卸载？(y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    systemctl stop nftables 2>/dev/null
    nft flush ruleset 2>/dev/null
    apt purge -y nftables > /dev/null 2>&1
    apt autoremove -y > /dev/null 2>&1
    rm -f "$RULES_FILE"
    rm -rf /etc/nftables/
    rm -f /usr/local/bin/nf
    echo -e "${GREEN}✅ 卸载完成，所有组件已清理干净。${NC}"
    exit 0
}

# 5. 主菜单
main_menu() {
    prepare_system
    while true; do
        clear
        echo -e "${CYAN}┌────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${WHITE}      NFTables 同步管理脚本 (nf)      ${CYAN}│${NC}"
        echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
        echo -e " 1. ${WHITE}添加${NC} 转发规则 (TCP+UDP同步)"
        echo -e " 2. ${WHITE}管理/同步删除/同步修改${NC}"
        echo -e " 3. ${WHITE}查看${NC} 系统状态"
        echo -e " 5. ${RED}彻底一键卸载${NC}"
        echo -e " 0. 退出"
        echo -e "${BLUE}----------------------------------------${NC}"
        read -p "请选择 [0-5]: " choice
        case $choice in
            1) add_forward_rule ;;
            2) manage_rules ;;
            3) sysctl net.ipv4.ip_forward net.ipv4.tcp_congestion_control ;;
            5) uninstall_all ;;
            0) exit 0 ;;
        esac
        read -p "按回车继续..."
    done
}

main_menu
