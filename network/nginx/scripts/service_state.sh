#!/bin/bash

# 状态文件
readonly SERVICE_STATES_FILE="/var/run/service_states.json"

# 服务操作状态
declare -A SERVICE_ACTIONS=(
	["UNKNOWN"]="unknown"			# 未初始化
	["INIT"]="init"					# 初始化
	["RUN"]="run"					# 运行
	["CLOSE"]="close"				# 关闭
	["UPDATE"]="update"				# 更新
	["RESTART"]="retart"			# 重启
)
readonly -A SERVICE_ACTIONS

# 服务状态枚举
declare -A SERVICE_STATUS=(
	["UNKNOWN"]="unknown"			# 未初始化
	["ENABLED"]="enabled"			# 已启用
	["DISABLED"]="disabled"			# 已禁用
	["RUNNING"]="running"			# 运行中
	["STOPPING"]="stopping"			# 停止中
	["STOPPED"]="stopped"			# 已停止
	["SUCCESS"]="success"			# 成功
	["FAILURE"]="failure"			# 失败
	["EXECUTING"]="executing"		# 执行中
	["SKIPPED"]="skipped"			# 跳过
	["UPDATING"]="updating"			# 更新中
)
readonly -A SERVICE_STATUS

# 服务实例注册表
declare -A SERVICE_REGISTRY=()

# ============================================================================
# 服务注册接口

# 注册服务
register_service()
{
	local service="$1"
	local opts="$2"
	
	if [[ -z "$service" ]]; then
		logger "ERROR" "注册服务名称不能为空!"
		return 1
	fi
	
	[[ -z "$opts" ]] && opts='{}'
	
	# 校验 JSON 格式
	echo "$opts" | jq empty >/dev/null 2>&1 || {
		logger "ERROR" "注册服务$service配置JSON格式不正确!"
		return 1
	}
	
	# 检查是否已注册
	if [[ -n "${SERVICE_REGISTRY[$service]:-}" ]]; then
		logger "DEBUG" "'$service'服务已注册"
		return 0
	fi
	
	# 解析字段
	local enabled=$(jq -r '.enabled // false' <<<"$opts")
	local updated=$(jq -r '.updated // false' <<<"$opts")
	local description=$(jq -r '.description // empty' <<<"$opts")
	local user=$(jq -r '.user // empty' <<<"$opts")
	local group=$(jq -r '.group // empty' <<<"$opts")
	local pid_file=$(jq -r '.pid_file // empty' <<<"$opts")
	local log_file=$(jq -r '.log_file // empty' <<<"$opts")
	local config=$(jq -c '.config // {}' <<<"$opts")
	
	local register_time=$(date '+%s')
	
	local register_json=$(jq -n \
		--arg service "$service" \
		--argjson enabled "$enabled" \
		--argjson updated "$updated" \
		--arg description "$description" \
		--arg user "$user" \
		--arg group "$group" \
		--arg pid_file "$pid_file" \
		--arg log_file "$log_file" \
		--arg time "$register_time" \
		--argjson config "$config" \
		'{
			service: $service,
			enabled: $enabled,
			updated: $updated,
			description: $description,
			user: $user,
			group: $group,
			pid_file: $pid_file,
			log_file: $log_file,
			register_time: $time,
			timestamp: $time,
			action: "none",
			state: {
				status: "unknown",
				pid: null,
				health: "unknown",
				last_start: null,
				last_stop: null,
				reason: null
			},
			config: $config
		}')
		
	# 注册到服务
	SERVICE_REGISTRY["$service"]="$register_json"
	logger "DEBUG" "注册服务: $service (enabled: $enabled, updated: $updated)"
}

# 导入模板
import_service_templates()
{
	logger "INFO" "开始导入服务模板"
	
	for template in "${SERVICE_TEMPLATES[@]}"; do
		[[ -z "$template" ]] && continue
		
		IFS=':' read -r service enabled updated description <<< "$template"
		
		# 构建注册选项
		local opts_json=$(jq -n \
			--argjson enabled "$([[ "$enabled" == "true" ]] && echo true || echo false)" \
			--argjson updated "$([[ "$updated" == "true" ]] && echo true || echo false)" \
			--arg description "$description" \
			--arg user "${USER_CONFIG[user]}" \
			--arg group "${USER_CONFIG[group]}" \
			'{
				enabled: $enabled,
				updated: $updated,
				description: $description,
				user: $user,
				group: $group
			}')
		
		# 注册服务
		register_service "$service" "$opts_json"
	done
	
	logger "INFO" "服务模板导入完成"
}

# 导入配置
import_service_config()
{
	local service="$1"
	local pid_file="$2"
	local log_file="$3"
	local config_json="$4"
	
	# 校验 JSON
	echo "$config_json" | jq empty >/dev/null 2>&1 || {
		logger "ERROR" "$service 配置不是规范的JSON格式"
		return 1
	}
	
	if [[ -n "$pid_file" ]]; then
		set_service_field "$service" "pid_file" "$pid_file"
	fi
	
	if [[ -n "$log_file" ]]; then
		set_service_field "$service" "log_file" "$log_file"
	fi
	
	local current=$(get_service_field "$service" "config")
	if [[ -z "$current" || "$current" == "{}" ]]; then
		set_service_field  "$service" "config" "$config_json" "json"
	fi
}

# ============================================================================
# 服务状态管理

# 加载服务状态
load_service_states()
{
	local user="${1:-}"
	local group="${2:-}"
	
	logger "INFO" "开始加载服务状态"
	
	# 导入状态
	import_service_states
	
	# 如果注册为空,初始化
	if [[ ${#SERVICE_REGISTRY[@]} -eq 0 ]]; then
		init_service_states "$user" "$group"
	else
		sync_service_states
	fi
	
	# 导出状态
	export_service_states || true 
	logger "INFO" "服务状态加载完成"
}

# 初始化服务状态
init_service_states()
{
	local user="${1:-}"
	local group="${2:-}"
	
	# 如果注册表为空, 从模板注册
	if [[ ${#SERVICE_REGISTRY[@]} -eq 0 ]]; then
		import_service_templates
	fi
	
	# 确保状态文件存在
	if [[ "$(id -u)" -eq 0 ]]; then
		if [[ ! -f "$SERVICE_STATES_FILE" ]]; then
			echo '{}' > "$SERVICE_STATES_FILE" 2>/dev/null || {
				logger "WARNING" "无法创建状态文件: $SERVICE_STATES_FILE"
				return 1
			}
		fi
		
		# 设置文件权限
		if [[ -n "$user" ]] && [[ -n "$group" ]]; then
			chown "$user:$group" "$SERVICE_STATES_FILE" 2>/dev/null || true
		fi
		
		chmod 666 "$SERVICE_STATES_FILE" 2>/dev/null || true
	fi
}

# 导入服务状态
import_service_states()
{
	# 检查文件是否存在
	[[ ! -f "$SERVICE_STATES_FILE" ]] && return
	
	logger "DEBUG" "从文件导入服务状态: $SERVICE_STATES_FILE"
	
	# 读取数据
	local json_data=$(cat "$SERVICE_STATES_FILE" 2>/dev/null)
	
	# 检查是否为空
	[[ -z "$json_data" ]] && return
	
	# 清空当前注册表
	unset SERVICE_REGISTRY 2>/dev/null || true
	declare -gA SERVICE_REGISTRY
	
	# 导入服务
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		
		local service=$(echo "$line" | jq -r '.service // ""')
		[[ -z "$service" ]] && continue
		
		# 规范化JSON
		local value=$(echo "$line" | jq -c '.')
		SERVICE_REGISTRY["$service"]="$value"
		
	done < <(echo "$json_data" | jq -c '.[]' 2>/dev/null)
}

# 同步服务状态
sync_service_states()
{
	# 布尔值转换
	_to_bool() {
		case "${1,,}" in
			true|1|yes|on|enabled)  echo "true";  return 0 ;;
			false|0|no|off|disabled) echo "false"; return 0 ;;
			*) return 1 ;;
		esac
	}
	
	# 同步字段
	_sync_field() {
		local service="$1" field="$2" template_value="$3"
		
		# 转换为布尔值
		local template_bool=$(_to_bool "$template_value")
		
		# 获取当前值
		local current
		current=$(get_service_field "$service" "$field" 2>/dev/null || echo "")
		
		# 转换为布尔值比较
		local current_bool=$(_to_bool "$current_value")
		
		# 比较值
		[[ "$current_bool" == "$template_bool" ]] && return 1
		
		# 更新字段
		set_service_field "$service" "$field" "$template_bool"
	}
	
	for template in "${SERVICE_TEMPLATES[@]}"; do
		[[ -z "$template" ]] && continue
		
		IFS=':' read -r service enable update _ <<< "$template"
		[[ -z "${SERVICE_REGISTRY[$service]:-}" ]] && continue
		
		# 同步 enabled 字段
		_sync_field "$service" "enabled" "$enable"
		
		# 同步 updated 字段
		_sync_field "$service" "updated" "$update"
	done
}

# 导出服务状态
export_service_states()
{
	local states_array=()
	
	# 收集所有服务状态
	for service in "${!SERVICE_REGISTRY[@]}"; do
		local service_json="${SERVICE_REGISTRY[$service]}"
		
		# 更新时间戳
		service_json=$(echo "$service_json" | jq -c \
			--arg timestamp "$(date '+%s')" \
			'.timestamp = $timestamp')
			
		states_array+=("$service_json")
	done
	
	# 构建JSON数组
	local json_array='[]'
	if [[ ${#states_array[@]} -gt 0 ]]; then
		json_array=$(printf '%s\n' "${states_array[@]}" | jq -sc '.')
	fi
	
	# 写入文件  2>/dev/null
	if ! echo "$json_array" > "$SERVICE_STATES_FILE"; then
		logger "WARNING" "无法写入状态文件: $SERVICE_STATES_FILE"
		return 1
	fi
}

# ============================================================================
# 服务状态操作

# 获取服务字段
get_service_field()
{
	local service="$1"
	local field="${2:-all}"
	
	# 验证服务注册
	local current_json="${SERVICE_REGISTRY[$service]}"
	[[ -z "$current_json" ]] && {
		logger "ERROR" "服务未注册: $service" >&2
		return 1
	}
	
	# 检查JSON格式
	if ! echo "$current_json" | jq empty >/dev/null 2>&1; then
		logger "ERROR" "服务$service注册数据JSON格式错误" >&2
		return 1
	fi
	
	case "$field" in
		"service")		echo "$current_json" | jq -r '.service' ;;
		"enabled")		echo "$current_json" | jq -r '.enabled' ;;
		"updated")		echo "$current_json" | jq -r '.updated' ;;
		"state")		echo "$current_json" | jq -c '.state // {}' ;;
		"config")		echo "$current_json" | jq -c '.config // {}' ;;
		"all")			echo "$current_json" ;;
		*)				echo "$current_json" | jq -r ".$field" ;;
	esac
}

# 设置服务字段
set_service_field()
{
	local service="$1"
	local field="$2"
	local value="$3"
	local type="${4:-string}"
	
	# 验证服务注册
	local current_json="${SERVICE_REGISTRY[$service]}"
	[[ -z "$current_json" ]] && {
		logger "ERROR" "服务未注册: $service"
		return 1
	}
	
	# 检查JSON格式
	if ! echo "$current_json" | jq empty >/dev/null 2>&1; then
		logger "ERROR" "服务$service注册数据JSON格式错误"
		return 1
	fi
	
	case "$type" in
		json)
			echo "$value" | jq empty >/dev/null 2>&1 || {
				logger "ERROR" "服务$service配置数据JSON格式错误"
				return 1
			}
			
			SERVICE_REGISTRY["$service"]=$(
				echo "$current_json" | jq --arg path "$field" \
					--argjson val "$value" \
					'setpath(($path | split(".")); $val)'
			)
			;;
		string|*)
			SERVICE_REGISTRY["$service"]=$(
				echo "$current_json" | jq --arg path "$field" \
					--arg val "$value" \
					'setpath(($path | split(".")); $val)'
			)
			;;
	esac
}

# 更新服务PID
update_service_pid()
{
	local service="$1"
	local pid="${2:-null}"
	
	set_service_field "$service" "state.pid" "$pid"
}

# 获取服务PID
get_service_pid()
{
	local service="$1"
	
	local pid
	pid=$(get_service_field "$service" "state.pid" 2>/dev/null) || return 1
	
	[[ -z "$pid" || "$pid" == "null" ]] && return 1
	echo "$pid"
}

# 更新服务健康状态
update_service_health()
{
	local service="$1"
	local health="${2:-unknown}"
	
	set_service_field "$service" "state.health" "$health"
}

# 检查服务是否存活
check_service_alive()
{
	local service="$1"
	local pid="${2:-}"
	
	if [[ -z "$pid" ]]; then
		# 读取 PID
		pid=$(get_service_field "$service" "state.pid" 2>/dev/null) || return 1
	fi
	
	# 未记录
	[[ -z "$pid" || "$pid" == "null" ]] && return 1
	
	# 进程是否存在
	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	
	# 验证进程是否真的是该服务
	if [[ -f "/proc/$pid/cmdline" ]]; then
		local cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
		if [[ ! "$cmdline" =~ $service ]]; then
			return 1
		fi
	else
		if ! ps -p "$pid" -o cmd= 2>/dev/null | grep -q "$service"; then
			return 1
		fi
	fi
	
	return 0
}

# 获取服务详细信息
get_service_info()
{
	local service="$1"
	
	# 验证服务注册
	local current_json="${SERVICE_REGISTRY[$service]}"
	[[ -z "$current_json" ]] && {
		logger "ERROR" "服务未注册: $service"
		return 1
	}
	
	# 检查JSON格式
	if ! echo "$current_json" | jq empty >/dev/null 2>&1; then
		logger "ERROR" "服务$service注册数据JSON格式错误"
		return 1
	fi
	
	local alive=false
	if check_service_alive "$service"; then
		alive=true
	fi
	
	# 构造增强 JSON（不写回 registry）
	echo "$current_json" | jq --argjson alive "$alive" '
		.state.alive = $alive
	'
}

# ============================================================================
# 服务管理

# 检查服务是否启用
check_service_enabled()
{
	local service="$1"
	
	local enabled
	enabled=$(get_service_field "$service" "enabled" 2>/dev/null) || return 1
	[[ "$enabled" == "true" ]]
}

# 检查服务是否支持更新
check_service_updated()
{
	local service="$1"
	
	local updated
	updated=$(get_service_field "$service" "updated" 2>/dev/null) || return 1
	[[ "$updated" == "true" ]]
}

# 获取服务 pid 文件路径
get_service_pid_file()
{
	local service="$1"
	
	local pid_file
	pid_file=$(get_service_field "$service" "pid_file" 2>/dev/null) || return 1
	
	if [[ -z "$pid_file" ]] || [[ "$pid_file" == "null" ]]; then
		# 返回默认路径
		echo "/var/run/${service}.pid"
	else
		echo "$pid_file"
	fi
}

# 获取服务日志文件路径
get_service_log_file()
{
	local service="$1"
	
	local log_file
	log_file=$(get_service_field "$service" "log_file" 2>/dev/null) || return 1
	
	if [[ -z "$log_file" ]] || [[ "$log_file" == "null" ]]; then
		# 返回默认路径
		echo "/var/log/${service}.log"
	else
		echo "$log_file"
	fi
}

# 设置服务操作状态
set_service_action()
{
	local service="$1"
	local action="$2"
	
	[[ -z "$service" || -z "$action" ]] && return 1
	
	# 验证操作状态
	local valid_action=false
	for op in "${SERVICE_ACTIONS[@]}"; do
		if [[ "$action" == "$op" ]]; then
			valid_action=true
			break
		fi
	done
	
	[[ "$valid_action" == "false" ]] && {
		logger "ERROR" "无效的操作状态: $action (有效值: ${SERVICE_ACTIONS[*]})"
		return 1
	}
	
	# 获取当前操作状态
	local current_action
	current_action=$(get_service_field "$service" "action" 2>/dev/null)
	
	# 状态未变化
	[[ "$current_action" == "$action" ]] && return 0
	
	# 更新操作状态
	set_service_field "$service" "action" "$action"
	
	case "$action" in
		"${SERVICE_ACTIONS[INIT]}")
			logger "INFO" "设置为初始化操作状态"
			;;
		"${SERVICE_ACTIONS[CLOSE]}")
			logger "INFO" "设置为关闭操作状态"
			;;
		"${SERVICE_ACTIONS[RUN]}")
			logger "INFO" "设置为运行操作状态"
			;;
		"${SERVICE_ACTIONS[UPDATE]}")
			logger "INFO" "设置为更新操作状态"
			;;
		"${SERVICE_ACTIONS[UNKNOWN]}")
			logger "DEBUG" "清除操作状态"
			;;
	esac
	
	logger "DEBUG" "操作状态更新: $service ($current_action → $action)"
}

# 获取服务操作状态
get_service_action()
{
	local service="$1"
	
	local action
	action=$(get_service_field "$service" "action" 2>/dev/null)
	
	echo "${action:-${SERVICE_ACTIONS[UNKNOWN]}}"
}

# 更新服务状态
update_service_states()
{
	local service="$1"
	local status="$2"
	local reason="${3:-}"
	
	[[ -z "$service" || -z "$status" ]] && return 1
	
	local current_status
	current_status=$(get_service_states "$service")
	
	# 状态未变化
	[[ "$current_status" == "$status" ]] && return 0
	
	# 更新状态
	set_service_field "$service" "state.status" "$status"
	
	# 写入原因
	[[ -n "$reason" ]] && set_service_field "$service" "state.reason" "$reason"
	
	# 更新额外依赖字段
	case "$status" in
		"${SERVICE_STATUS[RUNNING]}")
			set_service_field "$service" "state.last_start" "$(date '+%s')"
			set_service_field "$service" "state.health" "healthy"
			;;
		"${SERVICE_STATUS[STOPPED]}")
			set_service_field "$service" "state.last_stop" "$(date '+%s')"
			set_service_field "$service" "state.pid" "null"
			;;
		"${SERVICE_STATUS[FAILURE]}")
			set_service_field "$service" "state.health" "unhealthy"
			;;
	esac
	
	logger "DEBUG" "状态更新: $service ($current_status -> $status)"
}

# 获取服务状态
get_service_states()
{
	local service="$1"
	
	local status
	status=$(get_service_field "$service" "state.status" 2>/dev/null)
	
	echo "${status:-${SERVICE_STATUS[UNKNOWN]}}"
}

# 获取服务状态变更原因
get_service_reason()
{
	local service="$1"
	
	local reason
	reason=$(get_service_field "$service" "state.reason" 2>/dev/null)
	
	echo "${reason:-}"
}

# 处理服务状态
handle_service_status()
{
	local phase="$1"
	local service="$2"
	local action="$3"
	local data_json="${4:-}"
	
	[[ -z "$service" || -z "$action" ]] && return 1
	
	# JSON 校验
	if ! jq empty <<<"$data_json" 2>/dev/null; then
		data_json="{}"
	fi
	
	# 解析 JSON 数据
	local result=$(jq -r '.result // 0' <<<"$data_json")
	local pid=$(jq -r '.pid // empty' <<<"$data_json")
	
	# 设置操作状态 
	if [[ "$phase" == "pre" ]]; then
		if ! set_service_action "$service" "$action"; then
			logger "ERROR" "设置操作状态失败: $service -> $action"
			return 2
		fi
	fi
	
	# 处理执行失败 
	if [[ "$result" -ne 0 ]]; then
		update_service_states "$service" "${SERVICE_STATUS[FAILURE]}" "$action 执行失败"
		
		export_service_states || true
		return 0
	fi
	
	# 执行状态更新
	case "$action" in
		"${SERVICE_ACTIONS[INIT]}")
			if [[ "$phase" == "pre" ]]; then
				update_service_states "$service" "${SERVICE_STATUS[EXECUTING]}" "正在初始化"
			else
				update_service_states "$service" "${SERVICE_STATUS[SUCCESS]}" "初始化成功"
			fi
			;;
		"${SERVICE_ACTIONS[CLOSE]}")
			if [[ "$phase" == "pre" ]]; then
				update_service_states "$service" "${SERVICE_STATUS[STOPPING]}" "正在停止"
			else
				update_service_states "$service" "${SERVICE_STATUS[STOPPED]}" "停止成功"
				update_service_pid "$service" "null"
			fi
			;;
		"${SERVICE_ACTIONS[RUN]}")
			if [[ "$phase" == "post" ]]; then
				update_service_states "$service" "${SERVICE_STATUS[RUNNING]}" "启动成功"
				update_service_pid "$service" "$pid"
			fi
			;;
		"${SERVICE_ACTIONS[UPDATE]}")
			if [[ "$phase" == "pre" ]]; then
				update_service_states "$service" "${SERVICE_STATUS[UPDATING]}" "正在更新"
			fi
			;;
		*)
			logger "WARNING" "未知的操作类型: $action"
			return 1
			;;
	esac
	
	# 主进程统一导出
	export_service_states || true
}

# 动态构建执行函数
execute_service_func()
{
	local service="$1"
	local action="$2"
	local param="${4:-}"
	
	# 验证服务注册
	[[ -z "${SERVICE_REGISTRY[$service]:-}" ]] && {
		logger "ERROR" "服务未注册: $service"
		return 1
	}
	
	# 检查服务是否启用
	check_service_enabled "$service" || {
		logger "DEBUG" "服务 $service 未启用, 跳过 $action 操作"
		return 0
	}
	
	# 构建函数名
	local function_name="${action}_${service}_service"
	
	# 检查函数存在
	if ! type -t "$function_name" &>/dev/null; then
		logger "WARNING" "函数 '$function_name' 未定义"
		return 1
	fi
	
	local returned_pid=""
	
	# 操作前状态处理
	handle_service_status "pre" "$service" "$action"
	
	# 执行操作
	if [[ -n "$param" ]]; then
		$function_name "$param"
	else
		$function_name "returned_pid"
	fi
	
	local result=$?
	local data_json=$(jq -n \
		--argjson result "$result" \
		--arg pid "$returned_pid" \
		--argjson timestamp "$(date +%s)" \
		'{
			result: $result,
			pid: $pid,
			timestamp: $timestamp
		}')
	
	# 操作后状态处理
	handle_service_status "post" "$service" "$action" "$data_json"
	return $result
}

# ============================================================================
# 服务统计
_get_service_count_total()
{
	echo ${#SERVICE_REGISTRY[@]}
}

_get_service_count_enabled()
{
	local count=0
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		check_service_enabled "$service" && ((count++))
	done
	
	echo "$count"
}

_get_service_count_updated()
{
	local count=0
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		check_service_enabled "$service" && check_service_updated "$service" && ((count++))
	done
	
	echo "$count"
}

_get_service_count_status()
{
	local status="$1"
	local count=0
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		[[ "$(get_service_status "$service")" == "$status" ]] && ((count++))
	done
	
	echo "$count"
}

get_service_count()
{
	local type="$1"
	local arg="$2"
	
	case "$type" in
		total)
			_get_service_count_total
			;;
		enabled)
			_get_service_count_enabled
			;;
		updated)
			_get_service_count_updated
			;;
		status)
			_get_service_count_status "$arg"
			;;
		*)
			logger "ERROR" "未知的统计类型: $type"
			return 1
			;;
	esac
}