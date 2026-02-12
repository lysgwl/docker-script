#!/bin/bash

# 共享状态文件
readonly SHARED_STATE_FILE="/var/run/shared_service_states.json"

# PID 文件路径
readonly MAIN_PID_FILE="/var/run/filesync.pid"

# 定义共享的字段
declare -A SHARED_FIELDS=(
	["action"]="action"
	["status"]="state.status"
	["pid"]="state.pid"
	["health"]="state.health"
	["reason"]="state.reason"
)
readonly -A SHARED_FIELDS

# 回调函数变量
SHUTDOWN_CALLBACK=""

# 初始化状态文件
init_shared_state()
{
	[[ ! -f "$SHARED_STATE_FILE" ]] && echo '{}' > "$SHARED_STATE_FILE"
	chmod 666 "$SHARED_STATE_FILE" 2>/dev/null || true
}

# 生成共享状态
generate_shared_state()
{
	local service="$1"
	local field_json="$2"
	
	# 验证JSON格式
	if [[ -n "$field_json" ]] && ! echo "$field_json" | jq empty >/dev/null 2>&1; then
		logger "WARNING" "字段的JSON格式无效: $field_json"
		return 1
	fi
	
	# 提取共享字段
	local shared_json='{}'
	for key in "${!SHARED_FIELDS[@]}"; do
		local value=""
		
		if [[ -n "$field_json" ]]; then
			# 直接从提供的JSON获取
			value=$(echo "$field_json" | jq -r ".$key // \"\"" 2>/dev/null)
		else
			# 从服务状态中获取
			local service_json=$(get_service_field "$service" "all" 2>/dev/null || echo '{}')
			
			local field="${SHARED_FIELDS[$key]}"
			value=$(echo "$service_json" | jq -r ".$field // \"\"" 2>/dev/null)
		fi
		
		if [[ -n "$value" && "$value" != "null" ]]; then
			shared_json=$(echo "$shared_json" | jq \
					--arg key "$key" \
					--arg val "$value" \
					'. + {($key): $val}')
		fi
	done
	
	# 添加元数据
	shared_json=$(echo "$shared_json" | jq \
		--arg service "$service" \
		--arg timestamp "$(date +%s)" \
		'. + {_service: $service, _timestamp: $timestamp | tonumber}')
		
	echo "$shared_json"
}

# 更新共享状态
update_shared_state()
{
	local service="$1"
	local field_json="$2"
	
	# 生成状态
	local shared_state=$(generate_shared_state "$service" "$field_json" || echo '{}')
	
	# 原子化更新
	(
		flock -x 200 2>/dev/null || return 1
		
		local current_states='{}'
		if [[ -f "$SHARED_STATE_FILE" ]]; then
			current_states=$(cat "$SHARED_STATE_FILE" 2>/dev/null || echo '{}')
		fi
		
		# 更新状态
		local updated_states=$(echo "$current_states" | jq -c \
			--arg service "$service" \
			--argjson state "$shared_state" \
			'. + {($service): $state}')
		
		echo "$updated_states" > "$SHARED_STATE_FILE"
		
	) 200>"$SHARED_STATE_FILE.lock" 2>/dev/null
	
	return $?
}

# 读取共享状态
read_shared_state()
{
	local service="$1"
	local field="${2:-all}"
	
	(
		flock -s 200 2>/dev/null || return 1
		
		[[ ! -f "$SHARED_STATE_FILE" ]] && return 1
		
		if [[ "$field" == "all" ]]; then
			jq -c --arg service "$service" '.[$service] // empty' \
				"$SHARED_STATE_FILE" 2>/dev/null
		else
			jq -r --arg service "$service" --arg field "$field" \
				'.[$service][$field] // empty' \
				"$SHARED_STATE_FILE" 2>/dev/null
		fi
		
	) 200>"$SHARED_STATE_FILE.lock" 2>/dev/null
}

# 同步状态到内存
sync_from_shared_state()
{
	[[ ! -f "$SHARED_STATE_FILE" ]] && return 0
	
	# 读取共享状态
	local shared_states
	shared_states=$(
		(
			flock -s 200 || exit 1
			cat "$SHARED_STATE_FILE" 2>/dev/null || echo '{}'
		) 200>"$SHARED_STATE_FILE.lock"
	) || return 1
	
	# 遍历服务
	while read -r service; do
		[[ -z "$service" ]] && continue
		
		# 读取共享状态
		local shared_state=$(echo "$shared_states" | jq -c ".[\"$service\"]" 2>/dev/null)
		[[ -z "$shared_state" || "$shared_state" == "null" ]] && continue
		
		# 获取内存状态
		local memory_state=$(get_service_field "$service" "all" 2>/dev/null || echo '{}')
		
		# 检查时间戳
		local shared_ts=$(echo "$shared_state" | jq -r '._timestamp // 0' 2>/dev/null)
		local memory_ts=$(echo "$memory_state" | jq -r '.timestamp // 0' 2>/dev/null)
		
		# 共享状态较新时才更新
		[[ $shared_ts -le $memory_ts ]] && continue
		
		# 增量更新共享字段
		for key in "${!SHARED_FIELDS[@]}"; do
			local field="${SHARED_FIELDS[$key]}"
			local value=$(echo "$shared_state" | jq -r ".$key // empty" 2>/dev/null)
			
			[[ -n "$value" ]] && set_service_field "$service" "$field" "$value"
		done
		
		# 更新注册表时间戳
		local current_time=$(date '+%s')
		set_service_field "$service" "timestamp" "$current_time"
		
	done < <(echo "$shared_states" | jq -r 'keys[]')
	
	# 同步状态后导出
	export_service_states || true
}

# 发送状态更新信号
notify_state_update()
{
	[[ ! -f "$MAIN_PID_FILE" ]] && return 0
	
	# 读取主进程PID
	local main_pid=$(cat "$MAIN_PID_FILE" 2>/dev/null)
	
	# 发送信号
	[[ -n "$main_pid" ]] && kill -0 "$main_pid" 2>/dev/null && \
		kill -USR1 "$main_pid" 2>/dev/null
}

# 设置信号处理器
setup_signal_handler()
{
	local callback="$1"
	
	if [[ -n "$callback" ]]; then
		if declare -f "$callback" >/dev/null 2>&1; then
			SHUTDOWN_CALLBACK="$callback"
		fi
	fi
	
	# 处理状态更新信号
	trap 'handle_state_update' USR1
	
	# 处理终止信号
	trap 'handle_shutdown' TERM INT
	
	# 记录主进程PID
	echo $$ > "$MAIN_PID_FILE" 2>/dev/null
}

# 处理状态更新信号
handle_state_update()
{
	logger "INFO" "收到状态更新信号, 同步共享状态"
	
	# 同步共享状态
	sync_from_shared_state
}

# 处理关闭信号
handle_shutdown()
{
	# 停止监控进程
	stop_state_watcher
	
	# 执行业务回调
	if [[ -n "$SHUTDOWN_CALLBACK" ]] && declare -f "$SHUTDOWN_CALLBACK" >/dev/null 2>&1; then
		logger "INFO" "执行业务关闭回调: $SHUTDOWN_CALLBACK"
		"$SHUTDOWN_CALLBACK"
	fi
	
	# 清理资源
	rm -f "$MAIN_PID_FILE" \
		"/var/run/state_watcher.pid" \
		"$SHARED_STATE_FILE.lock" 2>/dev/null
	
	# 退出码
	exit 143
}

# 启动文件监控
start_state_watcher()
{
	[[ ! -f "$SHARED_STATE_FILE" ]] && init_shared_state
	
	# 检查 inotifywait
	if command -v inotifywait >/dev/null 2>&1; then
		# 启动监控
		(
			logger "INFO" "启动共享状态监控进程"
			
			# 设置退出信号
			trap 'exit 0' TERM INT
			
			while true; do
				# 监控共享状态文件的变化
				inotifywait -q -e modify,close_write "$SHARED_STATE_FILE" >/dev/null 2>&1
				
				# 文件变化时同步
				notify_state_update
			done
		) &
		
		local watcher_pid=$!
		echo $watcher_pid > "/var/run/state_watcher.pid" 2>/dev/null
	fi
}

# 停止监控
stop_state_watcher()
{
	local pid_file="/var/run/state_watcher.pid"
	[[ ! -f "$pid_file" ]] && return
	
	local watcher_pid=$(cat "$pid_file" 2>/dev/null)
	if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
		logger "INFO" "停止状态监控进程 (PID: $watcher_pid)"
		kill $watcher_pid 2>/dev/null
	fi
	
	rm -f "$pid_file" 2>/dev/null
}