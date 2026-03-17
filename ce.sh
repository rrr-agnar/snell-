#!/bin/bash

stty erase ^? 2>/dev/null
stty erase ^H 2>/dev/null

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1

CONF="/etc/nftables.conf"

init_env() {
    command -v nft >/dev/null 2>&1 || {
        apt update -y
        apt install -y nftables
    }

    echo 1 > /proc/sys/net/ipv4/ip_forward

    systemctl enable nftables >/dev/null 2>&1
    systemctl restart nftables

    nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
    nft list chain ip nat prerouting >/dev/null 2>&1 || \
        nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }

    nft list chain ip nat postrouting >/dev/null 2>&1 || \
        nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
}

save_rules() {
    nft list ruleset > $CONF
}

add_rule() {
    clear
    echo "--- 添加转发 ---"

    read -p "来源IP（留空=不限制）: " SRC
    read -p "本地端口 (如 1000 或 1000-1010): " LPORT
    read -p "目标IP: " DIP
    read -p "目标端口(回车=相同): " DPORT

    [[ -z "$LPORT" || -z "$DIP" ]] && echo "输入不完整" && sleep 1 && return

    [[ -z "$DPORT" ]] && TARGET="$DIP" || TARGET="$DIP:$DPORT"

    if [[ -z "$SRC" ]]; then
        nft add rule ip nat prerouting tcp dport $LPORT counter dnat to $TARGET
        nft add rule ip nat prerouting udp dport $LPORT counter dnat to $TARGET
    else
        nft add rule ip nat prerouting ip saddr $SRC tcp dport $LPORT counter dnat to $TARGET
        nft add rule ip nat prerouting ip saddr $SRC udp dport $LPORT counter dnat to $TARGET
    fi

    nft add rule ip nat postrouting ip daddr $DIP counter masquerade 2>/dev/null

    save_rules
    echo "✅ 添加成功"
    sleep 1
}

list_rules() {
    clear
    echo "--- 当前转发规则 ---"
    nft -a list chain ip nat prerouting | grep dnat
    echo "----------------------"
}

delete_rule() {
    mapfile -t HANDLES < <(nft -a list chain ip nat prerouting | grep dnat | awk '{print $NF}')

    [[ ${#HANDLES[@]} -eq 0 ]] && echo "无规则" && sleep 1 && return

    echo "--- 当前规则 ---"
    nft -a list chain ip nat prerouting | grep dnat | nl -w2 -s'. '

    echo "----------------------"
    read -p "输入编号删除（回车返回）: " NUM

    [[ -z "$NUM" ]] && return

    IDX=$((NUM-1))

    [[ -z "${HANDLES[$IDX]}" ]] && echo "无效编号" && sleep 1 && return

    nft delete rule ip nat prerouting handle ${HANDLES[$IDX]}

    save_rules
    echo "✅ 已删除"
    sleep 1
}

flush_all() {
    nft flush ruleset
    save_rules
    echo "✅ 已清空所有规则"
    sleep 1
}

# 🔥 新增：添加来源IP限制
add_src_ip() {
    mapfile -t RULES < <(nft -a list chain ip nat prerouting | grep dnat)

    [[ ${#RULES[@]} -eq 0 ]] && echo "无规则" && sleep 1 && return

    echo "--- 选择规则添加来源IP ---"
    printf "%s\n" "${RULES[@]}" | nl -w2 -s'. '

    read -p "选择编号: " NUM
    [[ -z "$NUM" ]] && return

    IDX=$((NUM-1))
    RULE="${RULES[$IDX]}"

    HANDLE=$(echo "$RULE" | awk '{print $NF}')
    PORT=$(echo "$RULE" | grep -oP 'dport \K[0-9-]+')
    TARGET=$(echo "$RULE" | grep -oP 'to \K[^ ]+')

    read -p "输入来源IP: " SRC
    [[ -z "$SRC" ]] && echo "未输入" && return

    nft delete rule ip nat prerouting handle $HANDLE

    nft add rule ip nat prerouting ip saddr $SRC tcp dport $PORT counter dnat to $TARGET
    nft add rule ip nat prerouting ip saddr $SRC udp dport $PORT counter dnat to $TARGET

    save_rules
    echo "✅ 已添加来源IP限制"
    sleep 1
}

# 🔥 新增：取消来源IP限制
remove_src_ip() {
    mapfile -t RULES < <(nft -a list chain ip nat prerouting | grep dnat)

    [[ ${#RULES[@]} -eq 0 ]] && echo "无规则" && sleep 1 && return

    echo "--- 选择规则取消来源IP ---"
    printf "%s\n" "${RULES[@]}" | nl -w2 -s'. '

    read -p "选择编号: " NUM
    [[ -z "$NUM" ]] && return

    IDX=$((NUM-1))
    RULE="${RULES[$IDX]}"

    HANDLE=$(echo "$RULE" | awk '{print $NF}')
    PORT=$(echo "$RULE" | grep -oP 'dport \K[0-9-]+')
    TARGET=$(echo "$RULE" | grep -oP 'to \K[^ ]+')

    nft delete rule ip nat prerouting handle $HANDLE

    nft add rule ip nat prerouting tcp dport $PORT counter dnat to $TARGET
    nft add rule ip nat prerouting udp dport $PORT counter dnat to $TARGET

    save_rules
    echo "✅ 已取消来源IP限制"
    sleep 1
}

uninstall_all() {
    echo "⚠️ 即将彻底卸载 nftables"
    read -p "输入 YES 确认: " CONFIRM

    [[ "$CONFIRM" != "YES" ]] && return

    nft flush ruleset 2>/dev/null
    systemctl stop nftables 2>/dev/null
    systemctl disable nftables 2>/dev/null

    apt purge -y nftables
    rm -rf /etc/nftables.conf

    echo "✅ 已彻底卸载"
    sleep 2
}

menu() {
    while true; do
        clear
        echo "==== NFT 转发管理 ===="
        echo "1. 添加规则"
        echo "2. 查看规则"
        echo "3. 删除规则"
        echo "4. 清空规则"
        echo "5. 彻底卸载"
        echo "6. 添加来源IP限制"
        echo "7. 取消来源IP限制"
        echo "8. 退出"
        echo "----------------------"
        read -p "选择: " CH

        case $CH in
            1) init_env; add_rule ;;
            2) list_rules; read -p "回车继续" ;;
            3) delete_rule ;;
            4) flush_all ;;
            5) uninstall_all ;;
            6) add_src_ip ;;
            7) remove_src_ip ;;
            8) exit ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

menu
