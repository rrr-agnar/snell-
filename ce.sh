#!/bin/bash

# ==========================================
# NFTABLES 转发管理工具（最终稳定版）
# 支持：
# ✔ 来源IP可选
# ✔ 多端口/范围
# ✔ 精准删除
# ✔ 一键清空
# ✔ 一键彻底卸载
# ==========================================

stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1

CONF="/etc/nftables.conf"

init_env() {
    if ! command -v nft &>/dev/null; then
        echo "安装 nftables..."
        apt update -y
        DEBIAN_FRONTEND=noninteractive apt install -y nftables
    fi

    echo 1 > /proc/sys/net/ipv4/ip_forward

    systemctl enable nftables >/dev/null 2>&1
    systemctl start nftables >/dev/null 2>&1

    nft list table ip nat &>/dev/null || nft add table ip nat
    nft list chain ip nat prerouting &>/dev/null || \
        nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }

    nft list chain ip nat postrouting &>/dev/null || \
        nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
}

save_rules() {
    nft list ruleset > $CONF
}

# ================= 添加规则 =================
add_rule() {
    echo "--- 添加转发 ---"

    read -p "来源IP（回车=不限制）: " SRC
    read -p "本地端口 (如 80 或 1000-1100): " LPORT
    read -p "目标IP: " RIP
    read -p "目标端口(回车同端口): " RPORT

    if [[ -z "$LPORT" || -z "$RIP" ]]; then
        echo "❌ 输入不完整"
        return
    fi

    if [[ -z "$RPORT" ]]; then
        TARGET="$RIP"
    else
        TARGET="$RIP:$RPORT"
    fi

    if [[ -z "$SRC" ]]; then
        MATCH=""
        echo "🌐 来源：不限制"
    else
        MATCH="ip saddr $SRC"
        echo "🔒 来源限制：$SRC"
    fi

    nft add rule ip nat prerouting $MATCH tcp dport $LPORT counter dnat to $TARGET
    nft add rule ip nat prerouting $MATCH udp dport $LPORT counter dnat to $TARGET
    nft add rule ip nat postrouting ip daddr $RIP counter masquerade

    save_rules

    echo "✅ 转发成功：$LPORT → $TARGET"
}

# ================= 查看/删除 =================
list_del() {
    while true; do
        clear
        echo "--- 当前转发规则 ---"

        RULES=$(nft -a list chain ip nat prerouting | grep dnat)

        if [[ -z "$RULES" ]]; then
            echo "空空如也..."
            read -p "回车返回..."
            break
        fi

        echo "$RULES" | nl
        echo "----------------------"
        read -p "输入编号删除（回车返回）: " NUM

        [[ -z "$NUM" ]] && break

        HANDLE=$(echo "$RULES" | sed -n "${NUM}p" | awk '{print $NF}')

        if [[ -n "$HANDLE" ]]; then
            nft delete rule ip nat prerouting handle $HANDLE
            save_rules
            echo "✅ 已删除"
        else
            echo "❌ 无效编号"
        fi

        sleep 1
    done
}

# ================= 清空 =================
flush_all() {
    nft flush ruleset
    save_rules
    echo "✅ 已清空所有规则"
}

# ================= 卸载 =================
uninstall_all() {
    echo "⚠️ 即将彻底卸载 nftables（不可恢复）"
    read -p "确认？(y/N): " CONFIRM

    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && return

    systemctl stop nftables 2>/dev/null
    systemctl disable nftables 2>/dev/null

    nft flush ruleset 2>/dev/null

    apt purge -y nftables
    apt autoremove -y

    rm -f /etc/nftables.conf

    echo "✅ 已彻底卸载干净"
}

# ================= 主菜单 =================
while true; do
    clear
    echo "==== NFT 转发管理 ===="
    echo "1. 添加规则"
    echo "2. 查看/删除"
    echo "3. 清空"
    echo "4. 退出"
    echo "5. 彻底卸载 nftables"
    echo "----------------------"
    echo -n "当前规则数: "
    nft list chain ip nat prerouting 2>/dev/null | grep -c dnat || echo 0
    echo "----------------------"

    read -p "选择: " OPT

    case $OPT in
        1) init_env; add_rule ;;
        2) list_del ;;
        3) flush_all ;;
        4) exit 0 ;;
        5) uninstall_all ;;
        *) echo "无效输入"; sleep 1 ;;
    esac
done
