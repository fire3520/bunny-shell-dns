#!/bin/bash

# ==========================
# 检查 curl
# ==========================
if ! command -v curl &>/dev/null; then
    echo "⚠️ curl 未安装，正在安装..."
    sudo apt update && sudo apt install -y curl
    if ! command -v curl &>/dev/null; then
        echo "❌ 安装 curl 失败，请手动安装"
        exit 1
    fi
fi

# ==========================
# 配置
# ==========================
BASE_URL="https://api.bunny.net"
API_KEY=""
read -p "请输入 Bunny API Key: " API_KEY
[[ -z "$API_KEY" ]] && echo "❌ 必须提供 API Key" && exit 1

# ==========================
# API 请求函数
# ==========================
api_request() {
    local method=$1
    local endpoint=$2
    local data=$3

    if [[ -n "$data" ]]; then
        curl -s -X "$method" "$BASE_URL$endpoint" \
            -H "AccessKey: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "$BASE_URL$endpoint" \
            -H "AccessKey: $API_KEY" \
            -H "Content-Type: application/json"
    fi
}

check_api_response() {
    local resp="$1"
    if echo "$resp" | grep -q '"ErrorKey"'; then
        local msg=$(echo "$resp" | grep -o '"Message":[^,}]*' | sed 's/"Message"://;s/^\"//;s/\"$//')
        echo "❌ 操作失败: $msg"
        return 1
    else
        echo "✅ 操作成功"
        return 0
    fi
}

get_json_field() {
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[^,}]*" | sed "s/\"$2\"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//"
}

# ==========================
# IP / Name 校验函数
# ==========================
is_valid_ipv4() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for octet in $(echo $ip | tr '.' ' '); do
        ((octet>=0 && octet<=255)) || return 1
    done
    return 0
}

is_valid_ipv6() {
    local ip=$1
    [[ $ip =~ ^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$ ]] && return 0
    return 1
}

is_valid_name() {
    local name=$(echo "$1" | tr -d '\r' | xargs)  # 去掉首尾空格和回车
    [[ -z "$name" ]] && { echo "❌ 记录名不能为空"; return 1; }
    [[ "$name" =~ ^[a-zA-Z0-9\-\_@]+$ ]] || { echo "❌ 记录名只能包含字母、数字、-、_ 或 @"; return 1; }
    return 0
}

# ==========================
# 区域管理
# ==========================
list_zones() {
    response=$(api_request GET "/dnszone")
    [[ -z "$response" ]] && echo "❌ 无法获取 DNS 区域" && return
    echo "=== DNS 区域 ==="
    echo "$response" | tr '{' '\n' | while read line; do
        id=$(get_json_field "$line" "Id")
        domain=$(get_json_field "$line" "Domain")
        [[ -n "$id" && -n "$domain" ]] && echo "$domain (ID: $id)"
    done
}

add_zone() {
    read -p "请输入要添加的域名: " domain
    domain=$(echo "$domain" | tr -d '\r' | xargs)
    [[ -z "$domain" ]] && echo "❌ 域名不能为空" && return
    resp=$(api_request POST "/dnszone" "{\"Domain\":\"$domain\"}")
    check_api_response "$resp"
}

delete_zone() {
    read -p "请输入要删除的 Zone ID: " zone_id
    read -p "确认删除 Zone $zone_id? (y/n): " confirm
    [[ "$confirm" != "y" ]] && echo "❌ 操作取消" && return
    resp=$(api_request DELETE "/dnszone/$zone_id")
    check_api_response "$resp"
}

# ==========================
# 记录管理
# ==========================
add_record() {
    local zone_id=$1
    echo "可选记录类型: A, AAAA, CNAME, MX, TXT, NS, Redirect"
    read -p "请输入记录类型: " type
    type=$(echo "$type" | tr '[:lower:]' '[:upper:]')
    read -p "请输入记录名 (www 或 @): " name
    name=$(echo "$name" | tr -d '\r' | xargs)
    is_valid_name "$name" || return
    read -p "请输入记录值: " value
    value=$(echo "$value" | tr -d '\r' | xargs)
    read -p "请输入 TTL (默认 300): " ttl
    ttl=${ttl:-300}

    declare -A type_map=([A]=1 [AAAA]=28 [CNAME]=5 [MX]=15 [TXT]=16 [NS]=2 [REDIRECT]=301)
    type_num=${type_map[$type]}
    [[ -z "$type_num" ]] && { echo "❌ 类型无效"; return; }

    if [[ "$type" == "A" ]]; then
        is_valid_ipv4 "$value" || { echo "❌ IPv4 地址不合法"; return; }
    elif [[ "$type" == "AAAA" ]]; then
        is_valid_ipv6 "$value" || { echo "❌ IPv6 地址不合法"; return; }
    fi

    if [[ "$type" == "MX" ]]; then
        read -p "请输入优先级 (默认 10): " priority
        priority=${priority:-10}
        data="{\"Type\":$type_num,\"Name\":\"$name\",\"Value\":\"$value\",\"Ttl\":$ttl,\"Priority\":$priority}"
    else
        data="{\"Type\":$type_num,\"Name\":\"$name\",\"Value\":\"$value\",\"Ttl\":$ttl}"
    fi

    resp=$(api_request PUT "/dnszone/$zone_id/records" "$data")
    check_api_response "$resp"
}

update_record() {
    local zone_id=$1
    read -p "请输入记录 ID: " record_id
    read -p "请输入记录类型: " type
    type=$(echo "$type" | tr '[:lower:]' '[:upper:]')
    read -p "请输入记录名 (www 或 @): " name
    name=$(echo "$name" | tr -d '\r' | xargs)
    is_valid_name "$name" || return
    read -p "请输入新的记录值: " value
    value=$(echo "$value" | tr -d '\r' | xargs)
    read -p "请输入 TTL (默认 300): " ttl
    ttl=${ttl:-300}

    declare -A type_map=([A]=1 [AAAA]=28 [CNAME]=5 [MX]=15 [TXT]=16 [NS]=2 [REDIRECT]=301)
    type_num=${type_map[$type]}
    [[ -z "$type_num" ]] && { echo "❌ 类型无效"; return; }

    if [[ "$type" == "A" ]]; then
        is_valid_ipv4 "$value" || { echo "❌ IPv4 地址不合法"; return; }
    elif [[ "$type" == "AAAA" ]]; then
        is_valid_ipv6 "$value" || { echo "❌ IPv6 地址不合法"; return; }
    fi

    if [[ "$type" == "MX" ]]; then
        read -p "请输入优先级 (默认 10): " priority
        priority=${priority:-10}
        data="{\"Type\":$type_num,\"Name\":\"$name\",\"Value\":\"$value\",\"Ttl\":$ttl,\"Priority\":$priority}"
    else
        data="{\"Type\":$type_num,\"Name\":\"$name\",\"Value\":\"$value\",\"Ttl\":$ttl}"
    fi

    resp=$(api_request POST "/dnszone/$zone_id/records/$record_id" "$data")
    check_api_response "$resp"
}

delete_record() {
    local zone_id=$1
    read -p "请输入记录 ID: " record_id
    read -p "确认删除记录 ID $record_id? (y/n): " confirm
    [[ "$confirm" != "y" ]] && echo "❌ 操作取消" && return
    resp=$(api_request DELETE "/dnszone/$zone_id/records/$record_id")
    check_api_response "$resp"
}

list_records() {
    local zone_id=$1
    response=$(api_request GET "/dnszone/$zone_id")
    [[ -z "$response" ]] && echo "❌ 无法获取记录" && return
    echo "=== Records in Zone $zone_id ==="
    echo "$response" | tr '{' '\n' | while read line; do
        rid=$(get_json_field "$line" "Id")
        type=$(get_json_field "$line" "Type")
        name=$(get_json_field "$line" "Name")
        value=$(get_json_field "$line" "Value")
        [[ -n "$rid" && -n "$type" ]] && echo "Type $type | $name -> $value (ID: $rid)"
    done
}

# ==========================
# 二级菜单：Zone 内管理记录
# ==========================
zone_menu() {
    read -p "请输入 Zone ID 进入管理: " zone_id
    zone_id=$(echo "$zone_id" | tr -d '\r' | xargs)
    [[ -z "$zone_id" ]] && echo "❌ Zone ID 不能为空" && return

    while true; do
        echo
        echo "=== Zone $zone_id 管理菜单 ==="
        echo "1. 查看记录"
        echo "2. 添加记录"
        echo "3. 更新记录"
        echo "4. 删除记录"
        echo "0. 返回主菜单"
        read -p "请选择操作: " choice
        choice=$(echo "$choice" | tr -d '\r' | xargs)

        case "$choice" in
            1) list_records "$zone_id" ;;
            2) add_record "$zone_id" ;;
            3) update_record "$zone_id" ;;
            4) delete_record "$zone_id" ;;
            0) break ;;
            *) echo "❌ 无效输入" ;;
        esac
    done
}

# ==========================
# 主菜单
# ==========================
while true; do
    echo
    echo "=== Bunny DNS 管理菜单 ==="
    echo "1. 查看 DNS 区域并管理记录"
    echo "2. 添加 DNS 区域"
    echo "3. 删除 DNS 区域"
    echo "4. 单独查看记录"
    echo "5. 单独添加记录"
    echo "6. 单独更新记录"
    echo "7. 单独删除记录"
    echo "0. 退出"
    read -p "请选择操作: " choice
    choice=$(echo "$choice" | tr -d '\r' | xargs)

    case "$choice" in
        1) list_zones; zone_menu ;;
        2) add_zone ;;
        3) delete_zone ;;
        4) read -p "请输入 Zone ID: " zid; zid=$(echo "$zid" | tr -d '\r' | xargs); list_records "$zid" ;;
        5) read -p "请输入 Zone ID: " zid; zid=$(echo "$zid" | tr -d '\r' | xargs); add_record "$zid" ;;
        6) read -p "请输入 Zone ID: " zid; zid=$(echo "$zid" | tr -d '\r' | xargs); update_record "$zid" ;;
        7) read -p "请输入 Zone ID: " zid; zid=$(echo "$zid" | tr -d '\r' | xargs); delete_record "$zid" ;;
        0) echo "退出程序"; exit 0 ;;
        *) echo "❌ 无效输入" ;;
    esac
done
