#!/bin/bash

# =========================================================
# Snell v5 全能一键管理脚本 (RackNerd & 精简系统优化版)
# =========================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 路径定义
BIN_PATH="/usr/local/bin/snell-server"
CONF_DIR="/etc/snell"
SCRIPT_PATH="/usr/local/bin/v5"

# 脚本初始化：检查 root 与 快捷启动
setup_init() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请使用 root 运行此脚本${PLAIN}" && exit 1
    
    # 强制创建配置目录
    mkdir -p "$CONF_DIR"

    # 设置快捷命令 v5
    if [[ "$0" != "$SCRIPT_PATH" ]]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
    
    # 修复 root 环境下 sudo 不存在的问题
    local cmd_pfx=""
    command -v sudo &> /dev/null && cmd_pfx="sudo "
    if ! grep -q "alias v5=" ~/.bashrc; then
        echo "alias v5='${cmd_pfx}${SCRIPT_PATH}'" >> ~/.bashrc
    fi
}

# 环境补全：防止解压失败
prepare_env() {
    echo -e "${GREEN}>>> 正在补齐系统环境...${PLAIN}"
    if command -v apt &> /dev/null; then
        apt update -y && apt install -y wget curl unzip iproute2 procps
    elif command -v yum &> /dev/null; then
        yum install -y wget curl unzip iproute procps
    fi
}

# 系统性能优化 (BBR + UDP)
optimize_system() {
    echo -e "${GREEN}>>> 正在开启系统网络优化 (BBR/TFO/UDP)...${PLAIN}"
    cat > /etc/sysctl.d/99-snell-opt.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=26214400
net.core.wmem_max=26214400
EOF
    sysctl --system
    echo -e "${GREEN}系统优化完成！${PLAIN}"
}

# 安装 Snell 内核
install_snell() {
    prepare_env
    
    ARCH=$(uname -m)
    URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    [[ "$ARCH" == "aarch64" ]] && URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"

    echo -e "${GREEN}>>> 正在从官方获取 Snell v5 内核...${PLAIN}"
    wget -qO /tmp/snell.zip "$URL"
    unzip -o /tmp/snell.zip -d /tmp/
    if [[ ! -f "/tmp/snell-server" ]]; then
        echo -e "${RED}内核下载/解压失败，请检查网络和磁盘。${PLAIN}"
        exit 1
    fi
    mv -f /tmp/snell-server "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -f /tmp/snell.zip

    # 写入 Systemd 模板
    cat > /etc/systemd/system/snell@.service <<EOF
[Unit]
Description=Snell v5 Service (%i)
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
ExecStart=$BIN_PATH -c $CONF_DIR/snell-%i.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    
    # 进入配置流
    config_wizard
}

# 配置向导
config_wizard() {
    echo -e "\n${BLUE}=== 开始配置 Snell 节点 ===${PLAIN}"
    
    # IPv4 配置
    read -p "是否启用 IPv4 节点? [Y/n]: " enable_v4
    if [[ ! "${enable_v4:-Y}" =~ [Nn] ]]; then
        read -p "端口 (回车随机): " port4
        port4=${port4:-$((RANDOM % 40000 + 20000))}
        read -p "密钥 PSK (回车随机): " psk4
        psk4=${psk4:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}
        
        cat > "$CONF_DIR/snell-v4.conf" <<EOF
[snell-server]
listen = 0.0.0.0:$port4
psk = $psk4
ipv6 = false
obfs = off
EOF
        systemctl enable "snell@v4" --now && systemctl restart "snell@v4"
        echo -e "${GREEN}IPv4 节点已在端口 $port4 启动。${PLAIN}"
    fi

    # IPv6 检测与配置
    local ipv6_test=$(curl -s6 --connect-timeout 2 icanhazip.com || echo "")
    if [[ -n "$ipv6_test" ]]; then
        read -p "检测到 IPv6 地址，是否开启 IPv6 节点? [y/N]: " enable_v6
        if [[ "${enable_v6:-N}" =~ [Yy] ]]; then
            read -p "IPv6 端口 (回车随机): " port6
            port6=${port6:-$((RANDOM % 40000 + 20000))}
            read -p "IPv6 PSK (回车随机): " psk6
            psk6=${psk6:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}
            
            cat > "$CONF_DIR/snell-v6.conf" <<EOF
[snell-server]
listen = [::]:$port6
psk = $psk6
ipv6 = true
obfs = off
EOF
            systemctl enable "snell@v6" --now && systemctl restart "snell@v6"
            echo -e "${GREEN}IPv6 节点已在端口 $port6 启动。${PLAIN}"
        fi
    fi
    
    show_status
}

# 修改配置逻辑 (交互式修改)
modify_config() {
    echo -e "${YELLOW}请选择要修改的节点:${PLAIN}"
    echo "1. 修改 IPv4 节点"
    echo "2. 修改 IPv6 节点"
    read -p "选择: " m_opt
    
    local target="v4"
    [[ "$m_opt" == "2" ]] && target="v6"
    
    if [[ ! -f "$CONF_DIR/snell-$target.conf" ]]; then
        echo -e "${RED}错误: 节点 $target 尚未安装。${PLAIN}"; return
    fi
    
    echo -e "${BLUE}>>> 正在修改 $target 节点 (回车保留原值)...${PLAIN}"
    local old_port=$(grep 'listen' "$CONF_DIR/snell-$target.conf" | awk -F':' '{print $NF}')
    local old_psk=$(grep 'psk' "$CONF_DIR/snell-$target.conf" | awk -F' = ' '{print $2}')
    
    read -p "新端口 (原 $old_port): " new_port
    new_port=${new_port:-$old_port}
    read -p "新 PSK (原 $old_psk): " new_psk
    new_psk=${new_psk:-$old_psk}
    
    local listen_addr="0.0.0.0"
    local ipv6_flag="false"
    [[ "$target" == "v6" ]] && listen_addr="[::]" && ipv6_flag="true"
    
    cat > "$CONF_DIR/snell-$target.conf" <<EOF
[snell-server]
listen = $listen_addr:$new_port
psk = $new_psk
ipv6 = $ipv6_flag
obfs = off
EOF
    systemctl restart "snell@$target"
    echo -e "${GREEN}修改成功并已重启服务！${PLAIN}"
    show_status
}

# 显示状态与配置信息
show_status() {
    echo -e "\n${BLUE}====== Snell v5 配置信息与状态 ======${PLAIN}"
    local count=0
    for conf in "$CONF_DIR"/snell-*.conf; do
        [[ ! -e "$conf" ]] && continue
        count=$((count+1))
        local tag=$(basename "$conf" .conf | cut -d- -f2)
        local port=$(grep 'listen' "$conf" | awk -F':' '{print $NF}')
        local psk=$(grep 'psk' "$conf" | awk -F' = ' '{print $2}')
        local ip=$(curl -s4 --connect-timeout 2 icanhazip.com || echo "你的服务器IP")
        [[ "$tag" == "v6" ]] && ip=$(curl -s6 --connect-timeout 2 icanhazip.com || echo "你的服务器IPv6")
        
        # 检查服务运行状态
        local status=$(systemctl is-active "snell@$tag")
        local status_icon="${GREEN}[运行中]${PLAIN}"
        [[ "$status" != "active" ]] && status_icon="${RED}[已停止/错误]${PLAIN}"

        echo -e "${YELLOW}节点: $tag $status_icon${PLAIN}"
        echo -e "Surge 5 配置行:"
        echo -e "${BLUE}snell, $ip, $port, psk=$psk, version=5, reuse=true, tfo=true${PLAIN}"
        echo -e "Shadowrocket 链接:"
        echo -e "${BLUE}snell://${psk}@${ip}:${port}?version=5&tfo=1${PLAIN}"
        echo "------------------------------------------------"
    done
    
    [[ $count -eq 0 ]] && echo -e "${RED}未检测到任何有效配置，请先选择 1 进行安装。${PLAIN}"
}

# 主菜单
main_menu() {
    setup_init
    clear
    echo -e "
${GREEN}Snell v5 管理脚本 [RackNerd 增强版]${PLAIN}
快捷命令: ${YELLOW}v5${PLAIN}
------------------------
1. 安装 / 重装 Snell (必选)
2. 查看配置信息与链接
3. 交互式修改配置 (端口/PSK)
4. 系统网络优化 (BBR/UDP)
5. 查看运行日志
6. 彻底卸载
0. 退出
------------------------"
    read -p "请选择: " opt
    case ${opt:-0} in
        1) install_snell ;;
        2) show_status ;;
        3) modify_config ;;
        4) optimize_system ;;
        5) journalctl -u "snell@*" -f ;;
        6) 
            systemctl stop "snell@*" && systemctl disable "snell@*"
            rm -rf "$CONF_DIR" "$BIN_PATH" "$SCRIPT_PATH" /etc/systemd/system/snell@.service
            systemctl daemon-reload
            echo "已卸载。"; exit ;;
        0) exit ;;
        *) main_menu ;;
    esac
}

main_menu
