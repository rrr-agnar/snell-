#!/bin/bash
set -euo pipefail

# ======== 基础 =========
[[ $EUID -ne 0 ]] && echo "请使用 root 运行（sudo）" && exit 1

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

BIN="/usr/local/bin/snell-server"
SCRIPT_PATH="/usr/local/bin/v5"
CONF_DIR="/etc/snell"

# ======== 自安装 =========
if [[ "$0" != "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    grep -q "alias v5=" ~/.bashrc || echo "alias v5='sudo $SCRIPT_PATH'" >> ~/.bashrc
fi

# ======== 工具 =========
rand_port(){ echo $((RANDOM % 40000 + 20000)); }
rand_psk(){ tr -dc A-Za-z0-9 </dev/urandom | head -c 16; }
ip4(){ curl -s4 icanhazip.com || echo N/A; }

# ======== 获取 eth0 IPv6（避开 WARP） =========
ip6_eth0(){
    ip -6 addr show dev eth0 scope global 2>/dev/null \
    | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1
}

# ======== systemd 模板 =========
install_systemd_template() {
cat > /etc/systemd/system/snell@.service <<EOF
[Unit]
Description=Snell v5 Instance %i
After=network.target

[Service]
Type=simple
ExecStart=$BIN -c /etc/snell/snell-%i.conf
Restart=on-failure
RestartSec=2
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

# ======== 安装 Snell =========
install_snell() {
    echo -e "${GREEN}开始安装 Snell v5...${PLAIN}"
    apt update
    apt install -y wget unzip curl

    URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    wget -O snell.zip "$URL"
    unzip -o snell.zip
    install -m 755 snell-server "$BIN"
    rm -f snell.zip snell-server

    mkdir -p "$CONF_DIR"
    install_systemd_template

    create_nodes
}

# ======== 创建节点 =========
create_nodes() {
    echo -e "${GREEN}配置 Snell 节点${PLAIN}"

    # ---------- IPv4 ----------
    read -p "是否创建 IPv4 节点？[Y/n]: " ENABLE_V4 < /dev/tty
    if [[ ! "$ENABLE_V4" =~ ^[Nn]$ ]]; then
        read -p "IPv4 端口 (回车随机): " PORT4 < /dev/tty
        [[ -z "$PORT4" ]] && PORT4=$(rand_port)

        read -p "IPv4 PSK (回车随机): " PSK4 < /dev/tty
        [[ -z "$PSK4" ]] && PSK4=$(rand_psk)

        cat > $CONF_DIR/snell-v4.conf <<EOF
[snell-server]
listen = 0.0.0.0:$PORT4
psk = $PSK4
ipv6 = false
obfs = off
EOF

        systemctl enable snell@v4 --now
        echo -e "${YELLOW}IPv4 节点已创建${PLAIN}"
        echo "snell, $(ip4), $PORT4, psk=$PSK4, version=5"
        echo
    fi

    # ---------- IPv6 ----------
    IPV6_ADDR=$(ip6_eth0)
    if [[ -n "$IPV6_ADDR" ]]; then
        read -p "是否创建 IPv6 节点？[y/N]: " ENABLE_V6 < /dev/tty
        if [[ "$ENABLE_V6" =~ ^[Yy]$ ]]; then
            read -p "IPv6 端口 (回车随机): " PORT6 < /dev/tty
            [[ -z "$PORT6" ]] && PORT6=$(rand_port)

            read -p "IPv6 PSK (回车随机): " PSK6 < /dev/tty
            [[ -z "$PSK6" ]] && PSK6=$(rand_psk)

            cat > $CONF_DIR/snell-v6.conf <<EOF
[snell-server]
listen = [::]:$PORT6
psk = $PSK6
ipv6 = true
obfs = off
EOF

            systemctl enable snell@v6 --now
            echo -e "${YELLOW}IPv6 节点已创建${PLAIN}"
            echo "snell, [$IPV6_ADDR], $PORT6, psk=$PSK6, version=5"
            echo
        fi
    else
        echo -e "${YELLOW}未检测到可用公网 IPv6，跳过 IPv6 节点${PLAIN}"
    fi
}

# ======== 状态 =========
status_snell() {
    systemctl status snell@v4 --no-pager || true
    systemctl status snell@v6 --no-pager || true

    echo
    [[ -f $CONF_DIR/snell-v4.conf ]] && {
        echo -e "${YELLOW}IPv4 配置:${PLAIN}"
        cat $CONF_DIR/snell-v4.conf
    }

    [[ -f $CONF_DIR/snell-v6.conf ]] && {
        echo -e "${YELLOW}IPv6 配置:${PLAIN}"
        cat $CONF_DIR/snell-v6.conf
    }
}

# ======== 卸载 =========
uninstall_snell() {
    systemctl stop snell@v4 snell@v6 || true
    systemctl disable snell@v4 snell@v6 || true
    rm -rf "$CONF_DIR"
    rm -f "$BIN" /etc/systemd/system/snell@.service
    systemctl daemon-reload
    echo -e "${GREEN}Snell 已完全卸载${PLAIN}"
}

# ======== 菜单 =========
show_menu() {
echo -e "${GREEN}
Snell v5 管理脚本
1. 安装 / 重装
2. 查看运行状态
3. 卸载
0. 退出
${PLAIN}"
read -p "选择: " c < /dev/tty
case $c in
    1) install_snell ;;
    2) status_snell ;;
    3) uninstall_snell ;;
    0) exit ;;
    *) show_menu ;;
esac
}

show_menu
