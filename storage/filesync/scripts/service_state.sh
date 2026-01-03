#!/bin/bash
# service_state.sh - 服务状态管理模块

export ENABLE_FILEBROWSER=false
export ENABLE_OPENLIST=true
export ENABLE_SYNCTHING=true
export ENABLE_VERYSYNC=true

# 服务状态枚举
declare -A SERVICE_STATUS=(
	["UNKNOWN"]="unknown"			# 未知/未初始化
	["INIT"]="init"					# 初始化
	["ENABLED"]="enabled"			# 已启用
	["DISABLED"]="disabled"			# 已禁用
	["RUNNING"]="running"			# 运行中
	["STOPPED"]="stopped"			# 已停止
	["SUCCESS"]="success"			# 成功
	["FAILURE"]="failure"			# 失败
	["EXECUTING"]="executing"		# 执行中（进行中）
)
readonly -A SERVICE_STATUS

# 服务列表
SERVICE_LIST_ARRAY=(
	"filebrowser:${ENABLE_FILEBROWSER:-false}"
	"openlist:${ENABLE_OPENLIST:-false}"
	"syncthing:${ENABLE_SYNCTHING:-false}"
	"verysync:${ENABLE_VERYSYNC:-false}"
)

# 服务实例
declare -A SERVICE_STATES=()

# ============================================================================
# 服务管理相关函数

# 初始化服务状态
init_service_status()
{
	# 检查是否被初始化
	if [[ ${#SERVICE_STATES[@]} -gt 0 ]]; then
		return 0
	fi
	
	for item in "${SERVICE_LIST_ARRAY[@]}"; do
		[[ -z "$item" ]] && continue
		
		IFS=':' read -r service enabled <<< "$item"
		
		# 创建JSON对象
		local state_json='{
			"service": "'$service'",
			"enabled": '$enabled',
			"status": "'${SERVICE_STATUS[INIT]}'",
			"timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'",
			"extra": {}
		}'

		SERVICE_STATES["$service"]="$state_json"
	done
}

# 获取服务状态字段
get_service_field()
{
	local service="$1"
	local field="${2:-all}"
	
	local json="${SERVICE_STATES[$service]}"
	if [[ -z "$json" ]]; then
		return 1
	fi
	
	if ! echo "$json" | jq empty >/dev/null 2>&1; then
		return 1
	fi
	
	case "$field" in
		"service")		echo "$json" | jq -r '.service' ;;
		"enabled")		echo "$json" | jq -r '.enabled' ;;
		"status")		echo "$json" | jq -r '.status' ;;
		"timestamp")	echo "$json" | jq -r '.timestamp' ;;
		"extra")		echo "$json" | jq -r '.extra' ;;	# 返回纯文本 JSON
		"extra_json")	echo "$json" | jq -c '.extra' ;;	# 返回紧凑 JSON
		"all")			echo "$json" ;;
		*)				echo "$json" | jq -r '.enabled' ;;
	esac
}

# 设置服务状态
set_service_state()
{
	local service="$1"
	local enabled="${2:-}"
	local status="${3:-}"
	local timestamp="${4:-}"
	local extra="${5:-}"
	
	# 获取当前状态
	local current_json="${SERVICE_STATES[$service]}"
	[[ -z "$current_json" ]] && return 1
	
	# 验证JSON格式
	if ! echo "$current_json" | jq empty >/dev/null 2>&1; then
		return 1
	fi
	
	# 构建更新命令
	timestamp="${timestamp:-$(date '+%Y-%m-%d %H:%M:%S')}"
	local cmd=".timestamp = \"$timestamp\""
	
	[[ -n "$enabled" ]] && cmd=".enabled = $enabled | $cmd"
	[[ -n "$status" ]] && cmd=".status = \"$status\" | $cmd"

	if [[ -n "$extra" ]]; then
		if echo "$extra" | jq empty >/dev/null 2>&1; then
			cmd=".extra = $extra | $cmd"
		else
			cmd=".extra.reason = \"$extra\" | $cmd"
		fi
	fi
	
	# 执行更新
	local update_json
	update_json=$(echo "$current_json" | jq -c "$cmd") || return 1
	
	# 保存并记录
	SERVICE_STATES["$service"]="$update_json"
}

# 检查服务是否启用
check_service_enabled()
{
	local service="$1"
	
	local enabled=$(get_service_field "$service" enabled 2>/dev/null) || return 1
	
	[[ "$enabled" == "true" ]]
}

# 获取服务当前状态
get_service_status()
{
	local service="$1"
	
	get_service_field "$service" "status"
}

# 获取服务状态变更原因
get_service_reason()
{
	local service="$1"
	
	# bash 正则解析JSON 
	# local extra=$(get_service_field "$service" "extra") || return 1
	# [[ "$extra" =~ reason=([^:]*) ]] && reason="${BASH_REMATCH[1]}"
	
	# 获取JSON格式
	local extra_json=$(get_service_field "$service" "extra_json")
	[[ -z "$extra_json" || "$extra_json" == "null" ]] && return 1
	
	# 提取 reason 字段
	local reason=$(echo "$extra_json" | jq -r '.reason // ""')
	
	echo "${reason:-}"
	[[ -n "$reason" ]] && return 0 || return 1
}

# 更新服务状态
update_service_status()
{
	local service="$1"
	local status="$2"
	local reason="${3:-}"
	
	local current_status=$(get_service_field "$service" "status")
	[[ "$current_status" == "$status" ]] && return 0
	
	local enabled=$(get_service_field "$service" "enabled")
	local extra=$(get_service_field "$service" "extra_json")
	
	if [[ -n "$reason" ]]; then
		echo "$extra" | jq empty >/dev/null 2>&1 || extra="{}"
		extra=$(echo "$extra" | jq --arg reason "$reason" '.reason = $reason')
	fi
	
	# 设置新状态
	set_service_state "$service" "$enabled" "$status" "" "$extra"
}

# 动态构建执行函数
execute_service_func()
{
	local service="$1"
	local operation="$2"
	local param="${3:-}"
	
	if check_service_enabled "$service"; then
		# 动态构建函数名
		local function_name="${operation}_${service}_service"
		
		if type -t "$function_name" &>/dev/null; then
			if [[ -n "$param" ]]; then
				$function_name "$param"
			else
				$function_name
			fi
			
			return $?
		fi
	fi
	
	return 0
}