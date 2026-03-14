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

# 1. 初始化快捷启动与系统环境
prepare_system() {
    # 设置快捷命令 nf
    if [ ! -f "/usr/local/bin/nf" ]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/nf
        chmod +x /usr/local/bin/nf
        echo -e "${GREEN}快捷启动已设置！以后只需输入 ${WHITE}nf${GREEN} 即可启动此脚本${NC}"
    fi

    # 开启 IP 转发
    if ! grep -q "net.ipv4.ip_forward = 1" $SYSCTL_CONF; then
        echo "net.ipv4.ip_forward = 1" >> $SYSCTL_CONF
    fi
    
    # BBR 优化
    if ! grep -q "net.core.default_qdisc = fq" $SYSCTL_CONF; then
        echo "net.core.default_qdisc = fq" >> $SYSCTL_CONF
        echo "net.ipv4.tcp_congestion_control = bbr" >> $SYSCTL_CONF
    fi
    sysctl -p > /dev/null 2>&1

    # 安装 nftables
    if ! command -v nft &> /dev/null; then
        echo "正在安装 nftables..."
        apt update && apt install -y nftables
    fi
    systemctl enable nftables > /dev/null 2>&1
    systemctl start nftables > /dev/null 2>&1
}

# 2. 添加转发规则
add_forward_rule() {
    echo -e "${WHITE}请输入转发规则信息：${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
    read -p "目标服务器 IP: " target_ip
    read -p "本地端口: " local_port
    read -p "目标端口: " target_port
    echo -e "${BLUE}----------------------------------------${NC}"

    if [[ -z "$target_ip" || -z "$local_port" || -z "$target_port" ]]; then
        echo -e "${RED}输入不能为空！${NC}"
        return
    fi

    # 创建基础表结构
    nft add table ip forward2jp
    nft add chain ip forward2jp prerouting { type nat hook prerouting priority dstnat \; }
    nft add chain ip forward2jp postrouting { type nat hook postrouting priority srcnat \; }

    # 添加规则 (TCP + UDP)
    nft add rule ip forward2jp prerouting tcp dport "${local_port}" dnat to "${target_ip}:${target_port}" comment "fwd_tcp_${local_port}"
    nft add rule ip forward2jp prerouting udp dport "${local_port}" dnat to "${target_ip}:${target_port}" comment "fwd_udp_${local_port}"
    
    # 全局 masquerade (确保回程路由正确)
    if ! nft list chain ip forward2jp postrouting | grep -q "masquerade"; then
        nft add rule ip forward2jp postrouting masquerade
    fi

    # 持久化
    nft list ruleset > "$RULES_FILE"
    echo -e "${GREEN}✅ 转发已开启: ${WHITE}${local_port} -> ${target_ip}:${target_port}${NC}"
}

# 3. 显示与删除规则
manage_rules() {
    clear
    echo -e "${CYAN}当前转发规则列表：${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    # 提取带有 comment 的规则并显示其 handle
    local rules=$(nft -a list table ip forward2jp 2>/dev/null | grep 'comment "fwd_')
    
    if [ -z "$rules" ]; then
        echo -e "  ${WHITE}暂无转发规则${NC}"
        echo -e "${BLUE}----------------------------------------------------------------${NC}"
        return
    fi

    echo "$rules" | awk '{
        # 提取端口、目标和 handle
        for(i=1;i<=NF;i++){
            if($i=="dport") lp=$(i+1);
            if($i=="to") tgt=$(i+1);
            if($i=="handle") h=$(i+1);
        }
        printf "协议: %-4s | 本地端口: %-6s | 目标: %-20s | Handle: %s\n", $1, lp, tgt, h
    }'
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    
    read -p "请输入要删除的 Handle 编号 (直接回车取消): " handle_num
    if [ -z "$handle_num" ]; then return; fi

    if nft delete rule ip forward2jp prerouting handle "$handle_num" 2>/dev/null; then
        nft list ruleset > "$RULES_FILE"
        echo -e "${GREEN}✅ 规则 [Handle: $handle_num] 已成功删除${NC}"
    else
        echo -e "${RED}❌ 删除失败，请检查 Handle 编号是否正确${NC}"
    fi
}

# 主菜单
main_menu() {
    prepare_system
    while true; do
        clear
        echo -e "${CYAN}┌────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${WHITE}      NFTables 转发管理器 (nf)        ${CYAN}│${NC}"
        echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
        echo -e " 1. ${WHITE}添加${NC} 转发规则 (TCP+UDP)"
        echo -e " 2. ${WHITE}管理/删除${NC} 现有规则"
        echo -e " 3. ${WHITE}查看${NC} 系统 BBR/转发状态"
        echo -e " 0. ${WHITE}退出${NC}"
        echo -e "${BLUE}----------------------------------------${NC}"
        read -p "选择操作 [0-3]: " choice

        case $choice in
            1) add_forward_rule ;;
            2) manage_rules ;;
            3) 
                echo -e "IP 转发状态: $(sysctl net.ipv4.ip_forward)"
                echo -e "BBR 状态: $(sysctl net.ipv4.tcp_congestion_control)"
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
        read -p "按回车键继续..."
    done
}

main_menu
