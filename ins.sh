#!/bin/bash
set -euo pipefail

# ==========================================
# Snell v5 Manager - 全能管理脚本
# ==========================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 核心路径与变量
BIN_NAME="snell-server"
BIN_PATH="/usr/local/bin/$BIN_NAME"
SCRIPT_PATH="/usr/local/bin/v5" # 快捷启动路径
CONF_DIR="/etc/snell"
SNELL_URL_BASE="https://dl.nssurge.com/snell/snell-server-v5.0.1"

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请使用 root 运行此脚本 (sudo -i)${PLAIN}" && exit 1

# ==========================================
# 基础工具函数
# ==========================================

# 1. 初始化快捷键 v5
install_shortcut() {
    local current_script=$(readlink -f "$0")
    if [[ "$current_script" != "$SCRIPT_PATH" ]]; then
        echo -e "${GREEN}正在配置快捷启动命令 'v5'...${PLAIN}"
        cp "$current_script" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}快捷命令已设置，以后输入 ${YELLOW}v5${GREEN} 即可管理脚本。${PLAIN}"
    fi
}

# 2. 检查端口占用
check_port() {
    local port=$1
    if command -v ss &> /dev/null; then
        ss -lntu | grep -q ":${port} "
    else
        netstat -lntu | grep -q ":${port} "
    fi
}

# 3. 生成随机端口
rand_port() {
    local port
    while true; do
        port=$((RANDOM % 40000 + 20000))
        if ! check_port "$port"; then
            echo "$port"
            break
        fi
    done
}

# 4. 生成强随机 PSK
rand_psk() { tr -dc A-Za-z0-9 </dev/urandom | head -c 20; }

# 5. 获取公网 IP
get_ip4() {
    curl -s4 --connect-timeout 3 https://api.ipify.org || \
    curl -s4 --connect-timeout 3 https://icanhazip.com || echo "N/A"
}

get_ip6() {
    # 智能获取默认路由网卡的 IPv6
    local iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    [[ -z "$iface" ]] && return
    ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -v "fd" | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1
}

# ==========================================
# 核心功能模块
# ==========================================

# --- 安装核心 ---
install_snell() {
    install_shortcut
    
    echo -e "${GREEN}>>> 正在检查环境...${PLAIN}"
    # 架构检测
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  DL_SUFFIX="linux-amd64.zip" ;;
        aarch64) DL_SUFFIX="linux-aarch64.zip" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    # 依赖安装
    if command -v apt &> /dev/null; then
        apt update -y && apt install -y wget unzip curl iproute2
    elif command -v yum &> /dev/null; then
        yum install -y wget unzip curl iproute
    fi

    echo -e "${GREEN}>>> 下载 Snell Server v5 ($ARCH)...${PLAIN}"
    wget -O /tmp/snell.zip "${SNELL_URL_BASE}-${DL_SUFFIX}"
    unzip -o /tmp/snell.zip -d /tmp/
    
    # 停止旧服务（如果存在）
    systemctl stop snell@v4 snell@v6 2>/dev/null || true
    
    mv /tmp/snell-server "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -f /tmp/snell.zip

    # 配置 Systemd 模板
    cat > /etc/systemd/system/snell@.service <<EOF
[Unit]
Description=Snell Proxy Service (%i)
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
ExecStart=$BIN_PATH -c /etc/snell/snell-%i.conf
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    mkdir -p "$CONF_DIR"

    echo -e "${GREEN}>>> 安装完成，开始配置节点...${PLAIN}"
    configure_node "v4" "IPv4"
    
    local ip6=$(get_ip6)
    if [[ -n "$ip6" ]]; then
        echo -e "\n${BLUE}检测到 IPv6 地址: $ip6${PLAIN}"
        configure_node "v6" "IPv6"
    else
        echo -e "\n${YELLOW}未检测到 IPv6，跳过 IPv6 配置。${PLAIN}"
    fi

    show_info
}

# --- 节点配置生成器 (通用) ---
configure_node() {
    local type=$1   # v4 或 v6
    local label=$2  # 显示名称
    local default_enable="Y"
    [[ "$type" == "v6" ]] && default_enable="N"

    echo -e "${YELLOW}--- 配置 $label 节点 ---${PLAIN}"
    read -p "是否启用 $label 节点? [y/n] (默认: $default_enable): " choice
    choice=${choice:-$default_enable}

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        return
    fi

    # 端口设置
    read -p "端口 (回车随机): " port
    [[ -z "$port" ]] && port=$(rand_port)
    if check_port "$port"; then
        echo -e "${RED}端口 $port 被占用，已自动更换为随机端口${PLAIN}"
        port=$(rand_port)
    fi

    # PSK 设置
    read -p "密钥 PSK (回车随机): " psk
    [[ -z "$psk" ]] && psk=$(rand_psk)

    # Obfs 设置
    read -p "启用 HTTP 混淆 (obfs)? [y/N]: " obfs_choice
    local obfs_val="off"
    if [[ "$obfs_choice" =~ ^[Yy]$ ]]; then
        obfs_val="http"
    fi

    # IPv6 标志
    local ipv6_flag="false"
    local listen_addr="0.0.0.0"
    if [[ "$type" == "v6" ]]; then
        ipv6_flag="true"
        listen_addr="[::]"
    fi

    # 写入配置
    cat > $CONF_DIR/snell-$type.conf <<EOF
[snell-server]
listen = $listen_addr:$port
psk = $psk
ipv6 = $ipv6_flag
obfs = $obfs_val
EOF

    systemctl enable snell@$type --now
    echo -e "${GREEN}$label 节点已启动！${PLAIN}"
}

# --- 修改配置 ---
modify_config() {
    echo -e "${YELLOW}请选择要修改的节点:${PLAIN}"
    echo "1. IPv4 节点"
    echo "2. IPv6 节点"
    read -p "选择: " node_type

    local type=""
    local conf_file=""
    
    case $node_type in
        1) type="v4";;
        2) type="v6";;
        *) echo "无效选择"; return;;
    esac
    
    conf_file="$CONF_DIR/snell-$type.conf"
    if [[ ! -f "$conf_file" ]]; then
        echo -e "${RED}配置文件不存在，请先安装。${PLAIN}"
        return
    fi

    # 读取旧配置
    local old_port=$(grep 'listen' $conf_file | awk -F':' '{print $NF}')
    local old_psk=$(grep 'psk' $conf_file | awk -F' = ' '{print $2}' | tr -d ' ')
    local old_obfs=$(grep 'obfs' $conf_file | awk -F' = ' '{print $2}' | tr -d ' ')
    local ipv6_flag=$(grep 'ipv6' $conf_file | awk -F' = ' '{print $2}' | tr -d ' ')
    local listen_prefix="0.0.0.0"
    [[ "$ipv6_flag" == "true" ]] && listen_prefix="[::]"

    echo -e "\n${BLUE}当前配置 ($type):${PLAIN} 端口=$old_port | PSK=$old_psk | Obfs=$old_obfs"
    echo "------------------------------------------------"
    
    # 修改端口
    read -p "输入新端口 (回车保留 $old_port): " new_port
    new_port=${new_port:-$old_port}
    
    # 修改 PSK
    read -p "输入新 PSK (回车保留 $old_psk): " new_psk
    new_psk=${new_psk:-$old_psk}

    # 修改 Obfs
    read -p "开启 Obfs (http)? [y/n] (回车保留): " obfs_yn
    local new_obfs=$old_obfs
    if [[ "$obfs_yn" =~ ^[Yy]$ ]]; then new_obfs="http"; fi
    if [[ "$obfs_yn" =~ ^[Nn]$ ]]; then new_obfs="off"; fi

    # 写入新配置
    cat > $conf_file <<EOF
[snell-server]
listen = $listen_prefix:$new_port
psk = $new_psk
ipv6 = $ipv6_flag
obfs = $new_obfs
EOF

    echo -e "${GREEN}正在重启服务...${PLAIN}"
    systemctl restart snell@$type
    echo -e "${GREEN}修改成功！${PLAIN}"
    show_info
}

# --- 打印链接信息 ---
print_link() {
    local name=$1
    local conf=$2
    local ip=$3
    
    [[ ! -f "$conf" ]] && return
    
    # 简单的配置解析
    local port=$(grep 'listen' "$conf" | awk -F':' '{print $NF}')
    local psk=$(grep 'psk' "$conf" | awk -F' = ' '{print $2}' | tr -d ' ')
    local obfs=$(grep 'obfs' "$conf" | awk -F' = ' '{print $2}' | tr -d ' ')
    
    local obfs_param=""
    [[ "$obfs" == "http" ]] && obfs_param=", obfs=http"
    local obfs_url="obfs=none"
    [[ "$obfs" == "http" ]] && obfs_url="obfs=http"

    echo -e "------------------------------------------------"
    echo -e "${YELLOW}节点: $name${PLAIN}"
    echo -e "地址: ${BLUE}$ip${PLAIN}"
    echo -e "端口: ${BLUE}$port${PLAIN}"
    echo -e "密钥: ${BLUE}$psk${PLAIN}"
    echo -e "混淆: $obfs"
    echo -e "\n${GREEN}[Surge 配置]${PLAIN}"
    echo "$name = snell, $ip, $port, psk=$psk, version=5, reuse=true, tfo=true$obfs_param"
    echo -e "\n${GREEN}[Shadowrocket 链接]${PLAIN}"
    echo "snell://${psk}@${ip}:${port}?peer=&${obfs_url}&tfo=1&version=5#${name}"
}

show_info() {
    echo -e "\n${GREEN}====== Snell 配置信息 ======${PLAIN}"
    if systemctl is-active --quiet snell@v4; then
        print_link "Snell-V4" "$CONF_DIR/snell-v4.conf" "$(get_ip4)"
    fi
    if systemctl is-active --quiet snell@v6; then
        print_link "Snell-V6" "$CONF_DIR/snell-v6.conf" "$(get_ip6)"
    fi
    echo -e "------------------------------------------------"
}

# --- 系统优化 ---
optimize_sys() {
    echo -e "${GREEN}正在应用 BBR 和网络优化...${PLAIN}"
    cat > /etc/sysctl.d/99-snell-opt.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=26214400
net.core.wmem_max=26214400
EOF
    sysctl -p /etc/sysctl.d/99-snell-opt.conf
    echo -e "${GREEN}优化完成！BBR 已开启，TCP Fast Open 已启用。${PLAIN}"
}

# --- 查看日志 ---
view_logs() {
    echo -e "${YELLOW}正在查看日志 (Ctrl+C 退出)...${PLAIN}"
    journalctl -u "snell@*" -f -n 20
}

# --- 卸载 ---
uninstall_snell() {
    read -p "确定要完全卸载 Snell v5 吗? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop snell@v4 snell@v6 2>/dev/null || true
        systemctl disable snell@v4 snell@v6 2>/dev/null || true
        rm -rf "$CONF_DIR"
        rm -f "$BIN_PATH" /etc/systemd/system/snell@.service
        rm -f "$SCRIPT_PATH"
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成。${PLAIN}"
    else
        echo "已取消。"
    fi
}

# ==========================================
# 主菜单
# ==========================================
show_menu() {
    clear
    install_shortcut # 确保每次运行菜单都检查快捷键
    echo -e "${GREEN}Snell v5 管理脚本${PLAIN} ${YELLOW}[全能版]${PLAIN}"
    echo -e "快捷命令: ${YELLOW}v5${PLAIN}"
    echo "------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装 / 重装 Snell"
    echo -e "${GREEN}2.${PLAIN} 查看配置信息 (链接)"
    echo -e "${GREEN}3.${PLAIN} 修改配置 (端口/PSK/Obfs)"
    echo -e "${GREEN}4.${PLAIN} 实时查看运行日志"
    echo -e "${GREEN}5.${PLAIN} 系统网络优化 (BBR+TFO)"
    echo -e "${GREEN}6.${PLAIN} 重启服务"
    echo -e "${RED}7.${PLAIN} 卸载"
    echo "0. 退出"
    echo "------------------------"
    read -p "请选择: " num

    case $num in
        1) install_snell ;;
        2) show_info ;;
        3) modify_config ;;
        4) view_logs ;;
        5) optimize_sys ;;
        6) systemctl restart "snell@*" && echo -e "${GREEN}服务已重启${PLAIN}" && sleep 1 && show_info ;;
        7) uninstall_snell ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${PLAIN}"; sleep 1; show_menu ;;
    esac
}

# 入口
if [[ $# > 0 ]]; then
    case $1 in
        install) install_snell ;;
        info) show_info ;;
        log) view_logs ;;
        *) show_menu ;;
    esac
else
    show_menu
fi
