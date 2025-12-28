#!/bin/bash

# ================= 基础变量 =================
CORE_FILE="/etc/proxy-core"
INFO_FILE="/root/proxy-info.txt"
SING_DIR="/etc/sing-box"
XRAY_DIR="/usr/local/etc/xray"
SSL_DIR="/etc/ssl"
IP=$(curl -s ipinfo.io/ip)

# ================= 通用函数 =================
pause(){ read -rp "按回车继续..."; }

ask_yes_no(){
  read -rp "$1 (y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

port_used(){ ss -lnt | awk '{print $4}' | grep -q ":$1$"; }

ask_port(){
  while true; do
    read -rp "端口(留空自动): " p
    if [ -z "$p" ]; then
      while true; do
        p=$(shuf -i 20000-60000 -n 1)
        port_used "$p" || break
      done
      echo "$p"; return
    fi
    port_used "$p" && echo "端口占用" || { echo "$p"; return; }
  done
}

ask_uuid(){
  read -rp "UUID(留空自动): " u
  [ -z "$u" ] && u=$(cat /proc/sys/kernel/random/uuid)
  echo "$u"
}

ask_pass(){
  read -rp "密码(留空自动): " p
  [ -z "$p" ] && p=$(openssl rand -hex 8)
  echo "$p"
}

gen_reality_key(){
  private=$(openssl rand -base64 32)
  public=$(echo -n "$private" | sha256sum | awk '{print $1}')
  echo "$private|$public"
}

install_base(){
  apt update -y
  apt install -y curl wget unzip tar socat nano openssl cron
}

# ================= 证书 =================
install_cert(){
  read -rp "输入域名: " domain
  read -rp "输入邮箱: " email

  mkdir -p $SSL_DIR
  curl https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --register-account -m $email
  ~/.acme.sh/acme.sh --issue --standalone -d $domain
  ~/.acme.sh/acme.sh --install-cert -d $domain \
    --key-file $SSL_DIR/key.pem \
    --fullchain-file $SSL_DIR/cert.pem

  echo "证书已生成：$SSL_DIR"
}

# ================= 内核安装 =================
install_singbox(){
  install_base
  ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d'"' -f4)
  wget -q https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-amd64.tar.gz
  tar -xzf sing-box-*.tar.gz
  mv sing-box-*/sing-box /usr/local/bin/
  chmod +x /usr/local/bin/sing-box
  mkdir -p $SING_DIR

cat >/etc/systemd/system/sing-box.service <<EOF
[Service]
ExecStart=/usr/local/bin/sing-box run -c $SING_DIR/config.json
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  echo "sing-box" > $CORE_FILE
}

install_xray(){
  install_base
  bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
  systemctl enable xray
  echo "xray" > $CORE_FILE
}

# ================= 协议 =================

install_vless(){
  port=$(ask_port); uuid=$(ask_uuid)
cat >$INFO_FILE <<EOF
VLESS
vless://$uuid@$IP:$port?encryption=none
EOF
}

install_vmess(){
  port=$(ask_port); uuid=$(ask_uuid)
cat >$INFO_FILE <<EOF
VMess
vmess://$uuid@$IP:$port
EOF
}

install_trojan(){
  port=$(ask_port); pass=$(ask_pass)
cat >$INFO_FILE <<EOF
Trojan
trojan://$pass@$IP:$port
EOF
}

install_ss(){
  port=$(ask_port); pass=$(ask_pass)
cat >$INFO_FILE <<EOF
Shadowsocks
ss://aes-128-gcm:$pass@$IP:$port
EOF
}

install_reality(){
  port=$(ask_port); uuid=$(ask_uuid)
read -rp "SNI(默认 www.cloudflare.com): " sni
[ -z "$sni" ] && sni="www.cloudflare.com"
keypair=$(gen_reality_key)
private=${keypair%%|*}
public=${keypair##*|}
cat >$INFO_FILE <<EOF
Reality
vless://$uuid@$IP:$port?security=reality&sni=$sni&pbk=$public
EOF
}

install_hysteria2(){
  port=$(ask_port); pass=$(ask_pass)
cat >$INFO_FILE <<EOF
Hysteria2
hy2://$pass@$IP:$port
EOF
}

install_tuic(){
  port=$(ask_port); pass=$(ask_pass)
cat >$INFO_FILE <<EOF
TUIC
tuic://$pass@$IP:$port
EOF
}

# ================= 菜单 =================
choose_core(){
  echo "1 sing-box"
  echo "2 xray"
  read -rp "选择: " c
  [ "$c" = "1" ] && install_singbox
  [ "$c" = "2" ] && install_xray
}

choose_proto(){
  CORE=$(cat $CORE_FILE)
  echo "1 VLESS"
  echo "2 Reality"
  echo "3 Trojan"
  echo "4 Shadowsocks"
  [ "$CORE" = "xray" ] && echo "5 VMess"
  [ "$CORE" = "sing-box" ] && echo "6 Hysteria2"
  [ "$CORE" = "sing-box" ] && echo "7 TUIC"
  read -rp "选择: " p
  case $p in
    1) install_vless ;;
    2) install_reality ;;
    3) install_trojan ;;
    4) install_ss ;;
    5) install_vmess ;;
    6) install_hysteria2 ;;
    7) install_tuic ;;
  esac
}

# ================= 主面板 =================
while true; do
clear
echo "========= 内置代理面板 ========="
echo "1 安装协议"
echo "2 查看节点信息"
echo "3 申请/更新证书"
echo "4 启动服务"
echo "5 卸载"
echo "0 退出"
read -rp "选择: " n

case $n in
  1) choose_core; choose_proto; pause ;;
  2) cat $INFO_FILE; pause ;;
  3) install_cert; pause ;;
  4) systemctl restart $(cat $CORE_FILE); pause ;;
  5) systemctl stop sing-box xray; rm -rf $SING_DIR $XRAY_DIR $INFO_FILE; pause ;;
  0) exit ;;
esac
done
