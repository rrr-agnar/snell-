#!/bin/bash
# Realm 转发管理脚本 - 支持 UDP

REALM_BIN="/usr/local/bin/realm"
CONFIG="/etc/realm/config.toml"
SERVICE="/etc/systemd/system/realm.service"

init() {
    mkdir -p /etc/realm
    if [ ! -f "$CONFIG" ]; then
        cat > "$CONFIG" << EOF
[network]
use_udp = true

# 示例规则
# [[endpoints]]
# listen = "0.0.0.0:1234"
# remote = "目标IP:目标端口"
EOF
    fi
}

add_rule() {
    echo "添加转发规则"
    read -p "本地监听端口: " listen_port
    read -p "目标地址:port (支持域名): " remote
    read -p "备注: " note

    cat >> "$CONFIG" << EOF

[[endpoints]]
listen = "0.0.0.0:$listen_port"
remote = "$remote"
# $note
EOF
    echo "规则添加成功！重启服务生效。"
    restart
}

list_rules() {
    echo "=== 当前规则 ==="
    grep -E "listen|remote" "$CONFIG" || echo "无规则"
}

delete_rule() {
    echo "当前规则："
    list_rules
    read -p "要删除的监听端口: " port
    # 简单 sed 删除（生产建议备份）
    sed -i "/listen = .*${port}/,/^$/d" "$CONFIG"
    echo "删除完成"
    restart
}

start_udp() { sed -i 's/use_udp = false/use_udp = true/' "$CONFIG" || echo "use_udp = true" >> "$CONFIG"; }

restart() { systemctl restart realm; systemctl status realm; }

# 快捷命令
case "$1" in
    add) add_rule ;;
    list) list_rules ;;
    del) delete_rule ;;
    restart) restart ;;
    *) echo "用法: zf add | list | del | restart" ;;
esac
