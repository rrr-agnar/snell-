#!/bin/bash
set -euo pipefail

# ==========================================
# Snell v5 Manager - 最终增强修复版
# ==========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

BIN_PATH="/usr/local/bin/snell-server"
SCRIPT_PATH="/usr/local/bin/v5"
CONF_DIR="/etc/snell"

# --- 基础检查与环境补齐 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 运行此脚本${PLAIN}" && exit 1

prepare_env() {
    if ! command -v wget &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}正在补齐必要工具 (wget/curl)...${PLAIN}"
        if command -v apt &> /dev/null; then
            apt update && apt install -y wget curl unzip iproute2
        elif command -v yum &> /dev/null; then
            yum install -y wget curl unzip iproute
        fi
    fi
}

# --- 快捷键修复逻辑 ---
install_shortcut() {
    local current_script=$(readlink -f "$0")
    # 生成快捷指令：如果有 sudo 则带上，没有则直接运行
    local cmd_prefix=""
    command -v sudo &> /dev/null && cmd_prefix="sudo "
    
    if [[ "$current_script" != "$SCRIPT_PATH" ]]; then
        cp "$current_script" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
    
    # 写入 alias 到 bashrc (如果不存在)
    if ! grep -q "alias v5=" ~/.bashrc; then
        echo "alias v5='${cmd_prefix}${SCRIPT_PATH}'" >> ~/.bashrc
        source ~/.bashrc 2>/dev/null || true
    fi
}

# --- 核心工具 ---
check_port() {
    (ss -lntu | grep -q ":$1 ") && return 0 || return 1
}

rand_port() {
    local port=$((RANDOM % 40000 + 20000))
    while check_port $port; do port=$((RANDOM % 40000 + 20000)); done
    echo $port
}

get_ip4() { curl -s4 --connect-timeout 3 https://api.ipify.org || echo "N/A"; }
get_ip6() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -v "fd" | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1 || echo ""
}

# --- 节点配置 ---
configure_node() {
    local type=$1
    local label=$2
    local listen_addr="0.0.0.0"
    [[ "$type" == "v6" ]] && listen_addr="[::]"

    echo -e "\n${BLUE}>>> 配置 $label 节点${PLAIN}"
    read -p "是否启用 $label ? [Y/n]: " choice
    [[ "${choice:-Y}" =~ ^[Nn]$ ]] && return

    read -p "端口 (回车随机): " port
    port=${port:-$(rand_port)}
    read -p "PSK密钥 (回车随机): " psk
    psk=${psk:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}

    cat > $CONF_DIR/snell-$type.conf <<EOF
[snell-server]
listen = $listen_addr:$port
psk = $psk
ipv6 = $( [[ "$type" == "v6" ]] && echo "true" || echo "false" )
obfs = off
EOF
    systemctl enable snell@$type --now
    echo -e "${GREEN}$label 已启动 (端口: $port)${PLAIN}"
}

# --- 安装主逻辑 ---
install_snell() {
    prepare_env
    echo -e "${GREEN}正在下载 Snell v5...${PLAIN}"
    ARCH=$(uname -m)
    URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    [[ "$ARCH" == "aarch64" ]] && URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    
    wget -O snell.zip "$URL"
    unzip -o snell.zip && mv snell-server "$BIN_PATH" && chmod +x "$BIN_PATH"
    rm -f snell.zip

    # Systemd Template
    cat > /etc/systemd/system/snell@.service <<EOF
[Unit]
Description=Snell %i
After=network.target
[Service]
ExecStart=$BIN_PATH -c $CONF_DIR/snell-%i.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    mkdir -p "$CONF_DIR"

    configure_node "v4" "IPv4"
    [[ -n "$(get_ip6)" ]] && configure_node "v6" "IPv6"
    show_info
}

# --- 显示信息 ---
show_info() {
    echo -e "\n${GREEN}====== Snell 配置信息 ======${PLAIN}"
    local count=0
    for conf in $CONF_DIR/snell-*.conf; do
        [[ ! -e "$conf" ]] && continue
        count=$((count+1))
        local type=$(basename "$conf" .conf | cut -d- -f2)
        local port=$(grep 'listen' "$conf" | awk -F':' '{print $NF}')
        local psk=$(grep 'psk' "$conf" | awk -F' = ' '{print $2}')
        local ip=$( [[ "$type" == "v4" ]] && get_ip4 || get_ip6 )
        
        echo -e "${YELLOW}节点类型: $type${PLAIN}"
        echo -e "配置行: ${BLUE}snell, $ip, $port, psk=$psk, version=5, reuse=true${PLAIN}"
    done
    [[ $count -eq 0 ]] && echo -e "${RED}未检测到任何已运行的节点，请先选择 1 进行安装。${PLAIN}"
    echo -e "------------------------------------------------"
}

# --- 菜单 ---
show_menu() {
    install_shortcut
    echo -e "
${GREEN}Snell v5 管理脚本 [修复版]${PLAIN}
快捷命令: ${YELLOW}v5${PLAIN}
------------------------
1. 安装 / 重装 Snell
2. 查看配置信息
3. 修改配置
4. 查看日志
5. 重启服务
6. 卸载
0. 退出
------------------------"
    read -p "选择: " opt
    case ${opt:-0} in
        1) install_snell ;;
        2) show_info ;;
        3) nano $CONF_DIR/snell-v4.conf && systemctl restart snell@v4 ;; # 简单处理
        4) journalctl -u "snell@*" -f ;;
        5) systemctl restart "snell@*" && echo "已重启" ;;
        6) systemctl stop "snell@*" && rm -rf "$CONF_DIR" "$BIN_PATH" && echo "已卸载" ;;
        0) exit ;;
        *) show_menu ;;
    esac
}

show_menu
