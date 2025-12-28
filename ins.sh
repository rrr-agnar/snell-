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
    # 第一次运行不强制 source，因为当前进程还在运行旧脚本，建议用户下次直接输入 v5
fi

# --- 菜单功能 ---
show_menu() {
    echo -e "
${GREEN}Snell v5 管理面板 (已优化卸载逻辑)${PLAIN}
---------------------------
1. 安装 Snell v5
2. 修改配置 (端口/PSK)
3. 卸载 Snell
4. 查看状态与日志
0. 退出
---------------------------"
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

# --- 1. 安装函数 ---
install_snell() {
    # 检查是否已安装
    if [[ -f $BIN ]]; then
        echo -e "${YELLOW}检测到系统已安装 Snell。${PLAIN}"
        read -p "是否覆盖旧版本并重新安装? [y/n]: " re_install < /dev/tty
        if [[ "$re_install" != "y" ]]; then
            echo -e "${YELLOW}已取消安装。${PLAIN}"
            return
        fi
        # 如果选y，先停止旧服务再覆盖
        systemctl stop snell >/dev/null 2>&1
    fi

    apt update && apt install -y unzip wget curl
    SNURL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    
    read -p "设置端口 (回车随机): " PORT < /dev/tty
    [[ -z "$PORT" ]] && PORT=$((RANDOM % 55535 + 10000))
    read -p "设置 PSK (回车随机): " PSK < /dev/tty
    [[ -z "$PSK" ]] && PSK=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

    echo -e "${YELLOW}正在下载核心文件...${PLAIN}"
    wget -O snell.zip "$SNURL"
    unzip -o snell.zip && chmod +x snell-server
    mv -f snell-server $BIN
    rm snell.zip

    mkdir -p $CONF_DIR
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

# --- 2. 修改配置 ---
edit_config() {
    if [[ ! -f $CONF ]]; then echo -e "${RED}未安装!${PLAIN}"; return; fi
    read -p "新端口 (不改请回车): " NEW_PORT < /dev/tty
    read -p "新 PSK (不改请回车): " NEW_PSK < /dev/tty
    [[ -n "$NEW_PORT" ]] && sed -i "s/listen = .*/listen = 0.0.0.0:$NEW_PORT/" $CONF
    [[ -n "$NEW_PSK" ]] && sed -i "s/psk = .*/psk = $NEW_PSK/" $CONF
    systemctl restart snell
    echo -e "${GREEN}配置已更新并重启!${PLAIN}"
}

# --- 3. 卸载函数 (重点优化) ---
uninstall_snell() {
    if [[ ! -f $BIN ]] && [[ ! -f $SERVICE ]]; then
        echo -e "${RED}系统未安装 Snell，无需卸载。${PLAIN}"
        return
    fi

    read -p "确定要彻底卸载 Snell 吗? 进程将被停止且文件会被删除 [y/n]: " confirm < /dev/tty
    if [[ "$confirm" == "y" ]]; then
        echo -e "${YELLOW}正在清理 Snell...${PLAIN}"
        # 1. 停止服务
        systemctl stop snell >/dev/null 2>&1
        # 2. 禁用自启
        systemctl disable snell >/dev/null 2>&1
        # 3. 删除服务文件
        rm -f $SERVICE
        # 4. 重载守护进程
        systemctl daemon-reload
        # 5. 删除二进制程序
        rm -f $BIN
        # 6. 删除配置文件目录
        rm -rf $CONF_DIR
        
        echo -e "${GREEN}Snell 已彻底停止并从系统中移除。${PLAIN}"
    else
        echo -e "${YELLOW}卸载已取消。${PLAIN}"
    fi
}

# --- 4. 状态 ---
check_status() {
    if ! systemctl is-active --quiet snell; then
        echo -e "${RED}Snell 服务当前未运行。${PLAIN}"
    else
        echo -e "${GREEN}Snell 正在运行!${PLAIN}"
    fi
    systemctl status snell --no-pager
    [[ -f $CONF ]] && echo -e "${YELLOW}当前配置内容：${PLAIN}" && cat $CONF
}

# 启动菜单
show_menu
