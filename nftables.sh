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

# 2. 添加规则函数
add_forward_rule() {
    echo -e "${WHITE}请输入转发规则信息：${NC}"
    read -p "目标服务器 IP: " target_ip
    read -p "本地端口: " local_port
    read -p "目标端口: " target_port

    if [[ -z "$target_ip" || -z "$local_port" || -z "$target_port" ]]; then
        echo -e "${RED}错误：输入不能为空${NC}"
        return
    fi

    nft add table ip forward2jp 2>/dev/null
    nft add chain ip forward2jp prerouting { type nat hook prerouting priority dstnat \; } 2>/dev/null
    nft add chain ip forward2jp postrouting { type nat hook postrouting priority srcnat \; } 2>/dev/null

    nft add rule ip forward2jp prerouting tcp dport "${local_port}" dnat to "${target_ip}:${target_port}" comment "fwd_tcp_${local_port}"
    nft add rule ip forward2jp prerouting udp dport "${local_port}" dnat to "${target_ip}:${target_port}" comment "fwd_udp_${local_port}"
    
    if ! nft list chain ip forward2jp postrouting | grep -q "masquerade"; then
        nft add rule ip forward2jp postrouting masquerade
    fi

    nft list ruleset > "$RULES_FILE"
    echo -e "${GREEN}✅ 规则已添加${NC}"
}

# 3. 管理/删除/修改规则
manage_rules() {
    clear
    echo -e "${CYAN}当前转发规则列表：${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    local rules=$(nft -a list table ip forward2jp 2>/dev/null | grep 'comment "fwd_')
    
    if [ -z "$rules" ]; then
        echo -e "  ${WHITE}暂无转发规则${NC}"
        echo -e "${BLUE}----------------------------------------------------------------${NC}"
        return
    fi

    # 格式化输出
    echo "$rules" | awk '{
        lp="?"; tgt="?"; h="?";
        for(i=1;i<=NF;i++){
            if($i=="dport") lp=$(i+1);
            if($i=="to") tgt=$(i+1);
            if($i=="handle") h=$(i+1);
        }
        printf "序号: %-2s | 协议: %-4s | 本地端口: %-6s | 目标: %-20s | Handle: %s\n", NR, $1, lp, tgt, h
    }'
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    
    echo -e "选项: [d] 删除规则 | [m] 修改规则 | [回车] 返回"
    read -p "请选择操作: " opt
    
    case $opt in
        d)
            read -p "请输入要删除的 Handle 编号: " h_num
            nft delete rule ip forward2jp prerouting handle "$h_num" && nft list ruleset > "$RULES_FILE"
            echo -e "${GREEN}已删除${NC}"
            ;;
        m)
            read -p "请输入要修改规则的 Handle 编号: " h_num
            echo -e "${WHITE}请输入新的信息：${NC}"
            read -p "新目标 IP: " n_ip
            read -p "新本地端口: " n_lp
            read -p "新目标端口: " n_tp
            # 先删再加实现修改
            nft delete rule ip forward2jp prerouting handle "$h_num" 2>/dev/null
            nft add rule ip forward2jp prerouting tcp dport "${n_lp}" dnat to "${n_ip}:${n_tp}" comment "fwd_tcp_${n_lp}"
            nft add rule ip forward2jp prerouting udp dport "${n_lp}" dnat to "${n_ip}:${n_tp}" comment "fwd_udp_${n_lp}"
            nft list ruleset > "$RULES_FILE"
            echo -e "${GREEN}修改成功！${NC}"
            ;;
        *) return ;;
    esac
}

# 4. 彻底卸载函数
uninstall_all() {
    echo -e "${RED}警告：这将清空所有规则并卸载 nftables！${NC}"
    read -p "确认卸载？(y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    echo -e "${WHITE}正在清理...${NC}"
    
    # 1. 停止服务并清空内核规则
    systemctl stop nftables 2>/dev/null
    nft flush ruleset 2>/dev/null
    
    # 2. 卸载程序
    apt purge -y nftables > /dev/null 2>&1
    apt autoremove -y > /dev/null 2>&1
    
    # 3. 删除残留文件
    rm -f "$RULES_FILE"
    rm -rf /etc/nftables/
    rm -f /usr/local/bin/nf
    
    # 4. 恢复 IP 转发 (可选，这里选择保留内核设置以防影响其他服务，如需关闭请手动执行)
    
    echo -e "${GREEN}✅ 卸载干净了！快捷命令 nf 已移除。${NC}"
    exit 0
}

# 5. 主菜单
main_menu() {
    prepare_system
    while true; do
        clear
        echo -e "${CYAN}┌────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${WHITE}      NFTables 增强管理脚本 (nf)      ${CYAN}│${NC}"
        echo -e "${CYAN}└────────────────────────────────────────┘${NC}"
        echo -e " 1. ${WHITE}添加${NC} 转发规则"
        echo -e " 2. ${WHITE}管理/删除/修改${NC} 现有规则"
        echo -e " 3. ${WHITE}查看${NC} 系统状态 (BBR/转发)"
        echo -e " 5. ${RED}彻底卸载${NC} Nftables 及脚本"
        echo -e " 0. 退出"
        echo -e "${BLUE}----------------------------------------${NC}"
        read -p "请选择 [0-5]: " choice

        case $choice in
            1) add_forward_rule ;;
            2) manage_rules ;;
            3) 
                echo -e "IP 转发: $(sysctl net.ipv4.ip_forward)"
                echo -e "BBR 状态: $(sysctl net.ipv4.tcp_congestion_control)"
                ;;
            5) uninstall_all ;;
            0) exit 0 ;;
        esac
        read -p "按回车继续..."
    done
}

main_menu
