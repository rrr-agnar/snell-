#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 路径定义
CONF_DIR="/etc/snell"
CONF="$CONF_DIR/snell-server.conf"
SERVICE="/etc/systemd/system/snell.service"
BIN="/usr/local/bin/snell-server"
SCRIPT_PATH="/usr/local/bin/v5"

# --- 自动安装脚本自身到系统 ---
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    sudo cp "$0" "$SCRIPT_PATH"
    sudo chmod +x "$SCRIPT_PATH"
    if ! grep -q "alias v5=" ~/.bashrc; then
        echo "alias v5='sudo $SCRIPT_PATH'" >> ~/.bashrc
    fi
fi

# --- 1. 安装函数 ---
install_snell() {
    if [[ -f $BIN ]]; then
        echo -e "${YELLOW}检测到已安装 Snell。${PLAIN}"
        read -p "是否覆盖安装? [y/n]: " re_install < /dev/tty
        [[ "$re_install" != "y" ]] && return
        systemctl stop snell >/dev/null 2>&1
    fi

    apt update && apt install -y unzip wget curl
    SNURL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    
    # 交互输入
    read -p "设置端口 (回车随机): " PORT < /dev/tty
    [[ -z "$PORT" ]] && PORT=$((RANDOM % 55535 + 10000))
    read -p "设置 PSK (回车随机): " PSK < /dev/tty
    [[ -z "$PSK" ]] && PSK=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

    # IPv6 自动检测与询问
    LISTEN_ADDR="0.0.0.0"
    IPV6_CONF="false"
    if [[ -n $(ip -6 addr show scope global) ]]; then
        read -p "检测到您的 VPS 支持 IPv6，是否开启? [y/n]: " enable_v6 < /dev/tty
        if [[ "$enable_v6" == "y" ]]; then
            LISTEN_ADDR="::"
            IPV6_CONF="true"
        fi
    fi

    wget -O snell.zip "$SNURL"
    unzip -o snell.zip && chmod +x snell-server
    mv -f snell-server $BIN
    rm snell.zip

    mkdir -p $CONF_DIR
    cat <<EOF > $CONF
[snell-server]
listen = $LISTEN_ADDR:$PORT
psk = $PSK
ipv6 = $IPV6_CONF
obfs = off
EOF

    cat <<EOF > $SERVICE
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=$BIN -c $CONF
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell --now
    
    IP4=$(curl -s4 icanhazip.com || echo "IPv4_NA")
    IP6=$(curl -s6 icanhazip.com || echo "IPv6_NA")

    echo -e "${GREEN}安装成功!${PLAIN}"
    echo -e "Surge 配置 (IPv4): ${YELLOW}MySnell = snell, $IP4, $PORT, psk=$PSK, version=5${PLAIN}"
    [[ "$IPV6_CONF" == "true" ]] && echo -e "Surge 配置 (IPv6): ${YELLOW}MySnell_v6 = snell, [$IP6], $PORT, psk=$PSK, version=5${PLAIN}"
}

# --- 2. 修改配置 ---
edit_config() {
    if [[ ! -f $CONF ]]; then echo -e "${RED}未安装!${PLAIN}"; return; fi
    echo -e "${YELLOW}当前配置：${PLAIN}"
    cat $CONF
    read -p "新端口 (回车不改): " NEW_PORT < /dev/tty
    read -p "新 PSK (回车不改): " NEW_PSK < /dev/tty
    read -p "是否开启 IPv6? [y/n/不改请回车]: " NEW_V6 < /dev/tty

    [[ -n "$NEW_PORT" ]] && sed -i "s/listen = .*/listen = 0.0.0.0:$NEW_PORT/" $CONF
    [[ -n "$NEW_PSK" ]] && sed -i "s/psk = .*/psk = $NEW_PSK/" $CONF
    
    if [[ "$NEW_V6" == "y" ]]; then
        sed -i "s/listen = .*/listen = :::$PORT/" $CONF
        sed -i "s/ipv6 = .*/ipv6 = true/" $CONF
    elif [[ "$NEW_V6" == "n" ]]; then
        sed -i "s/listen = .*/listen = 0.0.0.0:$PORT/" $CONF
        sed -i "s/ipv6 = .*/ipv6 = false/" $CONF
    fi

    systemctl restart snell
    echo -e "${GREEN}配置已更新!${PLAIN}"
}

# --- 3. 卸载 / 4. 状态 (保持不变) ---
uninstall_snell() {
    systemctl stop snell && systemctl disable snell
    rm -f $BIN $SERVICE $CONF && rm -rf $CONF_DIR
    echo -e "${GREEN}卸载完成!${PLAIN}"
}

check_status() {
    systemctl status snell --no-pager
    [[ -f $CONF ]] && cat $CONF
}

# --- 菜单界面 ---
show_menu() {
    echo -e "${GREEN}Snell v5 管理面板 (支持 IPv6)${PLAIN}
1. 安装 Snell v5
2. 修改配置
3. 卸载 Snell
4. 查看状态
0. 退出"
    read -p "选择: " choice < /dev/tty
    case $choice in
        1) install_snell ;;
        2) edit_config ;;
        3) uninstall_snell ;;
        4) check_status ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

show_menu
