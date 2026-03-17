#!/bin/bash

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1

CONF="/etc/nftables.conf"

# ================= 初始化 =================
init_env() {
    if ! command -v nft >/dev/null 2>&1; then
        echo "未检测到 nftables，正在安装..."
        apt update -y && apt install -y nftables
    fi

    # 只有 reset 才清空
    if [[ "$1" == "reset" ]]; then
        echo "[RESET] 清空 nftables 规则..."
        nft flush ruleset
    fi

    echo 1 > /proc/sys/net/ipv4/ip_forward

    nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
    nft list chain ip nat prerouting >/dev/null 2>&1 || \
        nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }

    nft list chain ip nat postrouting >/dev/null 2>&1 || \
        nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
}

save_rules() {
    nft list ruleset > $CONF
}

# ================= 添加规则 =================
add_rule() {
    clear
    echo "--- 添加转发 ---"

    echo "选择协议:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP"
    read -p "选择: " PROTO

    read -p "本地端口: " LPORT
    read -p "目标IP: " DIP
    read -p "目标端口(回车同端口): " DPORT

    [[ -z "$LPORT" || -z "$DIP" ]] && echo "输入不完整" && return

    [[ -z "$DPORT" ]] && TARGET="$DIP" || TARGET="$DIP:$DPORT"

    case $PROTO in
        1)
            nft add rule ip nat prerouting tcp dport $LPORT dnat to $TARGET
            ;;
        2)
            nft add rule ip nat prerouting udp dport $LPORT dnat to $TARGET
            ;;
        3)
            nft add rule ip nat prerouting tcp dport $LPORT dnat to $TARGET
            nft add rule ip nat prerouting udp dport $LPORT dnat to $TARGET
            ;;
        *)
            echo "无效选择"
            return
            ;;
    esac

    nft add rule ip nat postrouting ip daddr $DIP masquerade 2>/dev/null

    save_rules
    echo "✅ 添加成功"
    sleep 1
}

# ================= 查看规则（合并显示） =================
list_rules() {
    clear
    echo "--- 当前规则（合并显示）---"

    nft list chain ip nat prerouting | grep dnat | awk '
    {
        port=""; target=""; proto=""
        for(i=1;i<=NF;i++){
            if($i=="tcp") proto="TCP"
            if($i=="udp") proto="UDP"
            if($i=="dport") port=$(i+1)
            if($i=="to") target=$(i+1)
        }
        key=port"|"target
        if(proto=="TCP") tcp[key]=1
        if(proto=="UDP") udp[key]=1
    }
    END{
        i=1
        for(k in tcp){
            split(k,a,"|")
            if(udp[k])
                printf "%d. %s → %s [TCP/UDP]\n",i++,a[1],a[2]
            else
                printf "%d. %s → %s [TCP]\n",i++,a[1],a[2]
        }
        for(k in udp){
            if(!(k in tcp)){
                split(k,a,"|")
                printf "%d. %s → %s [UDP]\n",i++,a[1],a[2]
            }
        }
    }'
    echo "----------------------"
}

# ================= 删除规则 =================
delete_rule() {
    list_rules
    read -p "输入端口: " PORT

    echo "删除方式:"
    echo "1. 只删 TCP"
    echo "2. 只删 UDP"
    echo "3. 全删"
    read -p "选择: " MODE

    case $MODE in
        1)
            nft -a list chain ip nat prerouting | grep "tcp dport $PORT" | awk '{print $NF}' | \
            xargs -r -n1 nft delete rule ip nat prerouting handle
            ;;
        2)
            nft -a list chain ip nat prerouting | grep "udp dport $PORT" | awk '{print $NF}' | \
            xargs -r -n1 nft delete rule ip nat prerouting handle
            ;;
        3)
            nft -a list chain ip nat prerouting | grep "dport $PORT" | awk '{print $NF}' | \
            xargs -r -n1 nft delete rule ip nat prerouting handle
            ;;
        *)
            echo "无效"
            ;;
    esac

    save_rules
    echo "✅ 已处理"
    sleep 1
}

# ================= 清空 =================
flush_rules() {
    nft flush ruleset
    save_rules
    echo "✅ 已清空"
    sleep 1
}

# ================= 主菜单 =================
menu() {
    init_env "$1"

    while true; do
        clear
        echo "==== NFT 转发管理（终极版）===="
        echo "1. 添加规则"
        echo "2. 查看规则"
        echo "3. 删除规则"
        echo "4. 清空规则"
        echo "5. 退出"
        echo "----------------------"
        read -p "选择: " CH

        case $CH in
            1) add_rule ;;
            2) list_rules; read -p "回车继续" ;;
            3) delete_rule ;;
            4) flush_rules ;;
            5) exit ;;
        esac
    done
}

menu "$1"
