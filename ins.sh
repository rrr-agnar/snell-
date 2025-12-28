#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 路径定义
CONF="/etc/snell/snell-server.conf"
SERVICE="/etc/systemd/system/snell.service"
BIN="/usr/local/bin/snell-server"
SCRIPT_PATH="/usr/local/bin/v5"

# --- 自动安装脚本自身到系统 ---
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    echo -e "${YELLOW}正在初始化快捷指令...${PLAIN}"
    sudo cp "$0" "$SCRIPT_PATH"
    sudo chmod +x "$SCRIPT_PATH"
    if ! grep -q "alias v5=" ~/.bashrc; then
        echo "alias v5='sudo $SCRIPT_PATH'" >> ~/.bashrc
    fi
    echo -e "${GREEN}初始化成功！以后只需输入 v5 即可打开面板。${PLAIN}"
    # 继续向下执行，不退出
fi

# --- 菜单功能 ---
show_menu() {
    echo -e "
${GREEN}Snell v5 管理面板${PLAIN}
---------------------------
1. 安装 Snell v5
2. 修改配置 (端口/PSK)
3. 卸载 Snell
4. 查看状态与日志
0. 退出
---------------------------"
    # 明确指定从终端读取输入，修复跳动问题
    read -p "选择操作 [0-4]: " choice < /dev/tty
    case $choice in
        1) install_snell ;;
        2) edit_config ;;
        3) uninstall_snell ;;
        4) check_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入!${PLAIN}" && sleep 1 && show_menu ;;
    esac
}

install_snell() {
    apt update && apt install -y unzip wget curl
    SNURL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    
    read -p "设置端口 (回车随机): " PORT < /dev/tty
    [[ -z "$PORT" ]] && PORT=$((RANDOM % 55535 + 10000))
    read -p "设置 PSK (回车随机): " PSK < /dev/tty
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
}

edit_config() {
    if [[ ! -f $CONF ]]; then echo -e "${RED}未安装!${PLAIN}"; return; fi
    read -p "新端口 (不改请回车): " NEW_PORT < /dev/tty
    read -p "新 PSK (不改请回车): " NEW_PSK < /dev/tty
    [[ -n "$NEW_PORT" ]] && sed -i "s/listen = .*/listen = 0.0.0.0:$NEW_PORT/" $CONF
    [[ -n "$NEW_PSK" ]] && sed -i "s/psk = .*/psk = $NEW_PSK/" $CONF
    systemctl restart snell
    echo -e "${GREEN}配置已更新并重启!${PLAIN}"
}

uninstall_snell() {
    read -p "确定卸载? [y/n]: " confirm < /dev/tty
    if [[ "$confirm" == "y" ]]; then
        systemctl stop snell && systemctl disable snell
        rm -f $BIN $SERVICE $CONF
        echo -e "${GREEN}已卸载!${PLAIN}"
    fi
}

check_status() {
    systemctl status snell --no-pager
    [[ -f $CONF ]] && echo -e "${YELLOW}配置：${PLAIN}" && cat $CONF
}

# 启动菜单
show_menu
