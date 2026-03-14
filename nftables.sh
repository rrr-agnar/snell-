#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 路径定义
CONF_FILE="/root/nftables.conf"
SCRIPT_PATH="/usr/local/bin/nr"

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${PLAIN}" && exit 1

# 初始化系统环境
init_nft() {
    echo -e "${BLUE}开始安装 nftables 并优化内核转发...${PLAIN}"
    
    # 1. 安装软件包
    if [[ -n $(command -v apt) ]]; then
        apt update && apt install -y nftables
    elif [[ -n $(command -v yum) ]]; then
        yum install -y nftables
    fi

    # 2. 开启内核转发与优化
    cat <<EOF > /etc/sysctl.d/99-relay.conf
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_tw_reuse = 1
EOF
    sysctl -p /etc/sysctl.d/99-relay.conf

    # 3. 写入基础框架到 /root/nftables.conf
    # 彻底移除报错的 rt mtureduce，改用通用 MSS 钳制
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
        tcp flags syn tcp option maxseg size set 1400
    }
}
EOF
    # 4. 设置快捷启动 nr
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    # 5. 关联系统服务并强制加载
    ln -sf $CONF_FILE /etc/nftables.conf
    
    # 清理并重启服务
    systemctl stop nftables 2>/dev/null
    if nft -f $CONF_FILE; then
        systemctl enable nftables --now
        echo -e "${GREEN}初始化成功！以后只需输入 'nr' 即可管理。${PLAIN}"
    else
        echo -e "${RED}配置文件语法检测失败，请手动检查 /root/nftables.conf${PLAIN}"
    fi
}

# 添加转发规则
add_relay() {
    # 自动确保内核结构存在
    nft add table ip nat 2>/dev/null
    nft add map ip nat relay_map { type inet_service : ipv4_addr . inet_service \; } 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority dstnat \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority srcnat \; } 2>/dev/null

    read -p "请输入中转监听端口: " lport
    read -p "请输入落地机 IP: " rip
    read -p "请输入落地机端口 (默认同中转): " rport
    [[ -z "$rport" ]] && rport=$lport
    
    # 写入内核
    nft add element ip nat relay_map { $lport : $rip . $rport }
    nft add rule inet filter input tcp dport $lport accept
    nft add rule inet filter input udp dport $lport accept
    
    # 保存配置
    nft list ruleset > $CONF_FILE
    echo -e "${GREEN}添加成功: 本机 $lport -> $rip:$rport${PLAIN}"
}

# 删除转发规则
del_relay() {
    read -p "请输入要删除的中转端口: " lport
    nft delete element ip nat relay_map { $lport } 2>/dev/null
    nft list ruleset > $CONF_FILE
    echo -e "${YELLOW}端口 $lport 的转发已删除并保存。${PLAIN}"
}

# 查看列表
list_relay() {
    echo -e "${BLUE}--- 当前 nftables 转发映射表 ---${PLAIN}"
    # 修正：直接列出内存中的 elements，如果为空则友好提示
    res=$(nft list map ip nat relay_map 2>/dev/null | sed -n '/elements = {/,/}/p')
    if [[ -z "$res" || "$res" == *"elements = { }"* ]]; then
        echo -e "${YELLOW}目前没有任何转发规则${PLAIN}"
    else
        echo -e "$res"
    fi
    echo -e "${BLUE}-------------------------------${PLAIN}"
}

# 彻底卸载
uninstall_nft() {
    echo -e "${RED}警告: 此操作将删除所有规则并卸载快捷方式!${PLAIN}"
    read -p "确认卸载? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nftables
        systemctl disable nftables
        rm -f $CONF_FILE
        rm -f /etc/nftables.conf
        rm -f $SCRIPT_PATH
        rm -f /etc/sysctl.d/99-relay.conf
        echo -e "${YELLOW}所有配置已清理完毕。${PLAIN}"
        exit 0
    fi
}

# 菜单
while true; do
    echo -e "
  ${GREEN}nftables 极速中转工具 [nr]${PLAIN}
  ${BLUE}----------------------------${PLAIN}
  ${GREEN}1.${PLAIN} 初始化环境 (首次运行)
  ${GREEN}2.${PLAIN} 添加转发规则
  ${GREEN}3.${PLAIN} 删除转发规则
  ${GREEN}4.${PLAIN} 查看转发列表
  ${YELLOW}5.${PLAIN} 彻底卸载 nftables
  ${RED}0.${PLAIN} 退出
  ${BLUE}----------------------------${PLAIN}
  配置路径: ${YELLOW}$CONF_FILE${PLAIN}"
    read -p "选择操作: " num
    case "$num" in
        1) init_nft ;;
        2) add_relay ;;
        3) del_relay ;;
        4) list_relay ;;
        5) uninstall_nft ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
