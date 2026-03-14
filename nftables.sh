#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 配置文件存放位置
CONF_FILE="/root/nftables.conf"
SCRIPT_PATH="/usr/local/bin/nr"

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${PLAIN}" && exit 1

# 初始化环境
init_nft() {
    echo -e "${BLUE}正在初始化环境...${PLAIN}"
    
    # 安装软件
    if [[ -n $(command -v apt) ]]; then
        apt update && apt install -y nftables
    elif [[ -n $(command -v yum) ]]; then
        yum install -y nftables
    fi

    # 开启内核转发与优化
    cat <<EOF > /etc/sysctl.d/99-relay.conf
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_tw_reuse = 1
EOF
    sysctl -p /etc/sysctl.d/99-relay.conf

    # 写入基础框架到 /root/nftables.conf
    cat <<EOF > $CONF_FILE
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
    map relay_map {
        type inet_service : ipv4_addr . inet_service
    }
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        dnat ip addr . port to tcp dport map @relay_map
        dnat ip addr . port to udp dport map @relay_map
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        masquerade
    }
}
table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        tcp dport 22 accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        tcp flags syn tcp option maxseg size set rt mtureduce
    }
}
EOF
    # 设置快捷启动 nr
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    systemctl enable nftables --now
    # 强制让 nftables 读取 root 下的配置
    ln -sf $CONF_FILE /etc/nftables.conf
    
    echo -e "${GREEN}初始化成功！以后输入 'nr' 即可启动管理脚本。${PLAIN}"
}

# 添加转发
add_relay() {
    read -p "中转端口: " lport
    read -p "落地机 IP: " rip
    read -p "落地机端口 (默认同中转): " rport
    [[ -z "$rport" ]] && rport=$lport
    
    nft add element ip nat relay_map { $lport : $rip . $rport }
    nft add rule inet filter input tcp dport $lport accept
    nft add rule inet filter input udp dport $lport accept
    
    nft list ruleset > $CONF_FILE
    echo -e "${GREEN}添加完成: $lport -> $rip:$rport${PLAIN}"
}

# 删除转发
del_relay() {
    read -p "要删除的中转端口: " lport
    nft delete element ip nat relay_map { $lport }
    nft list ruleset > $CONF_FILE
    echo -e "${YELLOW}端口 $lport 转发已删除${PLAIN}"
}

# 卸载
uninstall_nft() {
    read -p "确定卸载并清理配置吗? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nftables
        systemctl disable nftables
        rm -f $CONF_FILE
        rm -f /etc/nftables.conf
        rm -f $SCRIPT_PATH
        echo -e "${YELLOW}已全数清理。${PLAIN}"
        exit 0
    fi
}

# 菜单小面包
while true; do
    echo -e "
  ${GREEN}nftables 中转工具 [nr]${PLAIN}
  ${BLUE}----------------------------${PLAIN}
  ${GREEN}1.${PLAIN} 初始化环境 (首次必选)
  ${GREEN}2.${PLAIN} 添加转发
  ${GREEN}3.${PLAIN} 删除转发
  ${GREEN}4.${PLAIN} 查看转发列表
  ${YELLOW}5.${PLAIN} 彻底卸载
  ${RED}0.${PLAIN} 退出
  ${BLUE}----------------------------${PLAIN}
  配置文件: ${YELLOW}$CONF_FILE${PLAIN}"
    read -p "请选择: " num
    case "$num" in
        1) init_nft ;;
        2) add_relay ;;
        3) del_relay ;;
        4) nft list map ip nat relay_map ;;
        5) uninstall_nft ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done
