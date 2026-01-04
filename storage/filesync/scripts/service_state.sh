#!/bin/bash
# service_state.sh - 服务状态管理模块

export ENABLE_FILEBROWSER=false
export ENABLE_OPENLIST=false
export ENABLE_SYNCTHING=false
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
	["SKIPPED"]="skipped"			# 跳过
)
readonly -A SERVICE_STATUS

# 服务列表 (服务名称:启用状态:更新支持)
SERVICE_LIST_ARRAY=(
	"filebrowser:${ENABLE_FILEBROWSER:-false}:false"
	"openlist:${ENABLE_OPENLIST:-false}:false"
	"syncthing:${ENABLE_SYNCTHING:-false}:false"
	"verysync:${ENABLE_VERYSYNC:-false}:true"
)

# 服务实例
declare -A SERVICE_STATES=()

# ============================================================================
# 服务管理相关函数

# 导出状态
export_service_states()
{
	local states_array=()
	for service in "${!SERVICE_STATES[@]}"; do
		states_array+=("${SERVICE_STATES[$service]}")
	done
	
	local json_array='[]'
	if [[ ${#states_array[@]} -gt 0 ]]; then
		json_array=$(printf '%s\n' "${states_array[@]}" | jq -sc '.')
	fi
	
	#export "$SERVICE_STATES_ENV"="$json_array"
	
	# 尝试写入文件
	if ! echo "$json_array" > "$SERVICE_STATES_FILE" 2>/dev/null; then
		print_log "WARNING" "无法写入状态文件: $SERVICE_STATES_FILE" >&2
	fi
}

# 导入状态
import_service_states()
{
	# 检查文件是否存在
	[[ ! -f "$SERVICE_STATES_FILE" ]] && return
	
	# 读取数据
	#local json_data="${!SERVICE_STATES_ENV:-}"
	local json_data=$(cat "$SERVICE_STATES_FILE" 2>/dev/null)
	
	# 检查是否为空
	[[ -z "$json_data" ]] && return
	
	# 清空当前状态
	unset SERVICE_STATES 2>/dev/null || true
	declare -gA SERVICE_STATES
	
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		
		local service=$(echo "$line" | jq -r '.service // ""')
		[[ -z "$service" ]] && continue
		
		local value=$(echo "$line" | tr -d '\n')
		SERVICE_STATES["$service"]="$value"
		
	done < <(echo "$json_data" | jq -c '.[]' 2>/dev/null)
}

# 初始化服务状态
init_service_status()
{
	local user="${1:-}"
	local group="${2:-}"
	
	# 检查是否被初始化
	if [[ ${#SERVICE_STATES[@]} -gt 0 ]]; then
		return 0
	fi

	# 只有root权限才能设置文件权限
	if [[ "$(id -u)" -eq 0 ]]; then
		# 确保状态文件存在
		if [[ ! -f "$SERVICE_STATES_FILE" ]]; then
			echo '[]' > "$SERVICE_STATES_FILE" 2>/dev/null || {
				print_log "WARNING" "无法创建状态文件: $SERVICE_STATES_FILE"
				return 1
			}
		fi
		
		# 设置文件所有权
		if ! chown "$user:$group" "$SERVICE_STATES_FILE" 2>/dev/null; then
			print_log "WARNING" "无法设置状态文件所有权"
		fi
		
		# 设置文件权限(644 666)
		if ! chmod 666 "$SERVICE_STATES_FILE" 2>/dev/null; then
			print_log "WARNING" "无法设置状态文件权限"
		fi
	fi
	
	# 初始化服务状态
	for item in "${SERVICE_LIST_ARRAY[@]}"; do
		[[ -z "$item" ]] && continue
		
		IFS=':' read -r service enabled updated <<< "$item"
		
		# 创建JSON对象
		local state_json='{
			"service": "'$service'",
			"enabled": '$enabled',
			"updated": '$updated',
			"status": "'${SERVICE_STATUS[INIT]}'",
			"timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'",
			"extra": {}
		}'

		SERVICE_STATES["$service"]="$state_json"
	done
	
	# 导出状态
	export_service_states || true 
}

# 加载服务状态
load_service_states()
{
	local user="${1:-}"
	local group="${2:-}"
	
	# 尝试导入已有状态
	import_service_states 2>/dev/null || true
	
	# 如果状态为空，初始化
	if [[ ${#SERVICE_STATES[@]} -eq 0 ]]; then
		init_service_status "$user" "$group"
	fi
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
		"updated")		echo "$json" | jq -r '.updated' ;;
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
	local updated="${3:-}"
	local status="${4:-}"
	local timestamp="${5:-}"
	local extra="${6:-}"
	
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
	[[ -n "$updated" ]] && cmd=".updated = $updated | $cmd"
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
	
	# 导出状态
	export_service_states
}

# 检查服务是否启用
check_service_enabled()
{
	local service="$1"
	
	local enabled=$(get_service_field "$service" "enabled" 2>/dev/null) || return 1
	
	[[ "$enabled" == "true" ]]
}

# 检查服务是否更新
check_service_updated()
{
	local service="$1"
	
	local updated=$(get_service_field "$service" "updated" 2>/dev/null) || return 1
	
	[[ "$updated" == "true" ]]
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
	local updated=$(get_service_field "$service" "updated")
	local extra=$(get_service_field "$service" "extra_json")
	
	if [[ -n "$reason" ]]; then
		echo "$extra" | jq empty >/dev/null 2>&1 || extra="{}"
		extra=$(echo "$extra" | jq --arg reason "$reason" '.reason = $reason')
	fi
	
	# 设置新状态
	set_service_state "$service" "$enabled" "$updated" "$status" "" "$extra"
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