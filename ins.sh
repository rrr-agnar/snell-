#!/bin/bash

# 检查权限
[[ $EUID -ne 0 ]] && echo "请使用 sudo 运行此脚本！" && exit 1

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 文件路径
CONF="/etc/snell/snell-server.conf"
SERVICE="/etc/systemd/system/snell.service"
BIN="/usr/local/bin/snell-server"

# --- 菜单界面 ---
show_menu() {
    clear
    echo -e "${GREEN}Snell v5 管理面板${PLAIN}"
    echo "---------------------------"
    echo "1. 安装 Snell v5"
    echo "2. 修改配置 (端口/PSK)"
    echo "3. 卸载 Snell"
    echo "4. 查看状态与日志"
    echo "0. 退出"
    echo "---------------------------"
    read -p "选择操作 [0-4]: " choice
    case $choice in
        1) install_snell ;;
        2) edit_config ;;
        3) uninstall_snell ;;
        4) check_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入!${PLAIN}" && sleep 2 && show_menu ;;
    esac
}

# --- 1. 安装 ---
install_snell() {
    apt update && apt install -y unzip wget curl
    
    # 自动获取 v5 链接
    SNURL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    
    echo -e "${YELLOW}开始安装 Snell v5...${PLAIN}"
    read -p "设置端口 (回车随机): " PORT
    [[ -z "$PORT" ]] && PORT=$((RANDOM % 55535 + 10000))
    
    read -p "设置 PSK (回车随机): " PSK
    [[ -z "$PSK" ]] && PSK=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

    wget -O snell.zip "$SNURL"
    unzip -o snell.zip && chmod +x snell-server
    mv -f snell-server $BIN
    rm snell.zip

    mkdir -p /etc/snell
    cat <<EOF > $CONF
[snell-server]
listen = 0.0.0.0:$PORT
psk = $PSK
ipv6 = false
obfs = off
EOF

    cat <<EOF > $SERVICE
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=32768
ExecStart=$BIN -c $CONF
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell --now
    echo -e "${GREEN}安装成功!${PLAIN}"
    echo -e "Surge 配置: ${YELLOW}MySnell = snell, $(curl -s ipv4.icanhazip.com), $PORT, psk=$PSK, version=5${PLAIN}"
    read -p "按回车返回..." var
    show_menu
}

# --- 2. 修改 ---
edit_config() {
    if [[ ! -f $CONF ]]; then
        echo -e "${RED}未安装 Snell!${PLAIN}"
    else
        read -p "新端口 (不改请回车): " NEW_PORT
        read -p "新 PSK (不改请回车): " NEW_PSK
        [[ -n "$NEW_PORT" ]] && sed -i "s/listen = .*/listen = 0.0.0.0:$NEW_PORT/" $CONF
        [[ -n "$NEW_PSK" ]] && sed -i "s/psk = .*/psk = $NEW_PSK/" $CONF
        systemctl restart snell
        echo -e "${GREEN}配置已更新!${PLAIN}"
    fi
    read -p "按回车返回..." var
    show_menu
}

# --- 3. 卸载 ---
uninstall_snell() {
    read -p "确定卸载 Snell? [y/n]: " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop snell && systemctl disable snell
        rm -f $BIN $SERVICE $CONF
        rm -rf /etc/snell
        echo -e "${GREEN}已彻底卸载!${PLAIN}"
    fi
    read -p "按回车返回..." var
    show_menu
}

# --- 4. 状态 ---
check_status() {
    systemctl status snell --no-pager
    [[ -f $CONF ]] && echo -e "${YELLOW}当前配置：${PLAIN}" && cat $CONF
    read -p "按回车返回..." var
    show_menu
}

show_menu
