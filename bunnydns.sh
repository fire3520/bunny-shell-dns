#!/bin/bash
# ...existing code...

# ==========================
# 检查 curl & jq
# ==========================
if ! command -v curl &>/dev/null; then
    echo "⚠️ curl 未安装，正在安装..."
    sudo apt update && sudo apt install -y curl
    if ! command -v curl &>/dev/null; then
        echo "❌ 安装 curl 失败，请手动安装"
        exit 1
    fi
fi

USE_JQ=0
if command -v jq &>/dev/null; then
    USE_JQ=1
else
    echo "⚠️ 建议安装 jq 用于更好解析 JSON：sudo apt install -y jq"
fi

# ==========================
# 配置（支持环境变量）
# ==========================
BASE_URL="https://api.bunny.net"
API_KEY="${BUNNY_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    read -p "请输入 Bunny API Key: " API_KEY
fi
[[ -z "$API_KEY" ]] && echo "❌ 必须提供 API Key（可通过环境变量 BUNNY_API_KEY 提供）" && exit 1

# ==========================
# API 请求函数（返回 body + 状态码）
# ==========================
api_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local resp

    if [[ -n "$data" ]]; then
        resp=$(curl -s -X "$method" "$BASE_URL$endpoint" \
            -H "AccessKey: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$data" -w "\n%{http_code}")
    else
        resp=$(curl -s -X "$method" "$BASE_URL$endpoint" \
            -H "AccessKey: $API_KEY" \
            -H "Content-Type: application/json" \
            -w "\n%{http_code}")
    fi

    # 输出 body 和 status（status 为最后一行）
    echo "$resp"
}

check_api_response() {
    local resp="$1"
    local status=$(echo "$resp" | tail -n1 | tr -d '\r')
    local body=$(echo "$resp" | sed '$d' | tr -d '\r')

    # 成功的常见状态码：200, 201, 204
    if [[ "$status" =~ ^(200|201|204)$ ]]; then
        echo "✅ 操作成功 (HTTP $status)"
        return 0
    fi

    # 尝试解析错误信息
    local msg=""
    if [[ $USE_JQ -eq 1 ]]; then
        msg=$(echo "$body" | jq -r '.Message // .message // empty')
    fi
    if [[ -z "$msg" ]]; then
        msg=$(echo "$body" | grep -o '"Message":[^,}]*' | sed 's/"Message"://;s/^\"//;s/\"$//' || true)
    fi
    msg=${msg:-"HTTP $status"}
    echo "❌ 操作失败: $msg"
    return 1
}

get_json_field() {
    # 兼顾 jq 与简单正则解析（仅在无法使用 jq 时）
    local body="$1"
    local field="$2"
    if [[ $USE_JQ -eq 1 ]]; then
        echo "$body" | jq -r --arg f "$field" 'if type=="array" then .[0][$f] // empty else .[$f] // empty end' 2>/dev/null
    else
        echo "$body" | grep -o "\"$field\"[[:space:]]*:[^,}]*" | sed "s/\"$field\"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//"
    fi
}

# ==========================
# IP / Name 校验函数（保持现有实现）
# ==========================
# ...existing code...
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
    local name=$(echo "$1" | tr -d '\r' | xargs)
    [[ -z "$name" ]] && { echo "❌ 记录名不能为空"; return 1; }
    [[ "$name" =~ ^[a-zA-Z0-9\-\_@]+$ ]] || { echo "❌ 记录名只能包含字母、数字、-、_ 或 @"; return 1; }
    return 0
}
# ...existing code...

# ==========================
# 区域管理（使用更可靠的 JSON 解析）
# ==========================
list_zones() {
    local resp=$(api_request GET "/dnszone")
    local status=$(echo "$resp" | tail -n1 | tr -d '\r')
    local body=$(echo "$resp" | sed '$d' | tr -d '\r')

    if [[ ! "$status" =~ ^(200|201)$ ]]; then
        check_api_response "$resp" || return
    fi

    echo "=== DNS 区域 ==="
    if [[ $USE_JQ -eq 1 ]]; then
        echo "$body" | jq -r '.[] | "\(.Domain) (ID: \(.Id))"' 2>/dev/null || echo "❌ 解析结果失败"
    else
        # 兼容旧解析方式（按对象分割）
        echo "$body" | tr '{' '\n' | while read -r line; do
            id=$(echo "$line" | grep -o "\"Id\"[[:space:]]*:[^,}]*" | sed 's/"Id"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//')
            domain=$(echo "$line" | grep -o "\"Domain\"[[:space:]]*:[^,}]*" | sed 's/"Domain"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//')
            [[ -n "$id" && -n "$domain" ]] && echo "$domain (ID: $id)"
        done
    fi
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
# 记录管理（list 使用 jq 或回退解析）
# ==========================
add_record() {
    # ...existing code...
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
    # ...existing code...
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
    local resp=$(api_request GET "/dnszone/$zone_id")
    local status=$(echo "$resp" | tail -n1 | tr -d '\r')
    local body=$(echo "$resp" | sed '$d' | tr -d '\r')

    if [[ ! "$status" =~ ^(200|201)$ ]]; then
        check_api_response "$resp" || return
    fi

    echo "=== Records in Zone $zone_id ==="
    if [[ $USE_JQ -eq 1 ]]; then
        echo "$body" | jq -r '.Records? // .[]? | if type=="object" then "\(.Id) \(.Type) \(.Name) -> \(.Value)" else tostring end' 2>/dev/null
    else
        echo "$body" | tr '{' '\n' | while read -r line; do
            rid=$(echo "$line" | grep -o "\"Id\"[[:space:]]*:[^,}]*" | sed 's/"Id"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//')
            type=$(echo "$line" | grep -o "\"Type\"[[:space:]]*:[^,}]*" | sed 's/"Type"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//')
            name=$(echo "$line" | grep -o "\"Name\"[[:space:]]*:[^,}]*" | sed 's/"Name"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//')
            value=$(echo "$line" | grep -o "\"Value\"[[:space:]]*:[^,}]*" | sed 's/"Value"[[:space:]]*:[[:space:]]*//;s/^\"//;s/\"$//')
            [[ -n "$rid" && -n "$type" ]] && echo "Type $type | $name -> $value (ID: $rid)"
        done
    fi
}

# ...existing code...
# 主菜单（保持不变）
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