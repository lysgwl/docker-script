#!/bin/bash

# 设置系统用户
set_service_user()
{
	# 创建用户目录
	logger "DEBUG" "正在创建用户目录"
	mkdir -p "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[install_dir]}" \
			 "${SYSTEM_CONFIG[update_dir]}" \
			 "${SYSTEM_CONFIG[config_dir]}" \
			 "${SYSTEM_CONFIG[data_dir]}" \
			 "${SYSTEM_CONFIG[usr_dir]}"
	
	# 设置目录拥有者
	logger "DEBUG" "正在设置目录拥有者(${user_config[user]}:${user_config[group]})"
	chown -R ${user_config[user]}:${user_config[group]} \
			 "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[update_dir]}" \
			"${SYSTEM_CONFIG[config_dir]}" \
			"${SYSTEM_CONFIG[data_dir]}"
			
	chown "${user_config[user]}:${user_config[group]}" \
			"${SYSTEM_CONFIG[usr_dir]}"
}

# 获取服务配置
get_service_config()
{
	local service="$1"
	local field="${2:-config}"
	local ref_name="${3:-SERVICE_CONFIG}"
	
	# 获取配置JSON
	local field_value
	field_value=$(get_service_field "$service" "$field" 2>/dev/null) || return 1
	
	if [[ -z "$field_value" ]] || [[ "$field_value" == "null" ]]; then
		logger "WARNING" "服务 $service 的 $field 配置信息为空"
		return 1
	fi
	
	# 声明全局数组
	declare -gA "$ref_name"
	local -n config_array="$ref_name"
	
	# 清空内容
	config_array=()
	
	if ! echo "$field_value" | jq empty >/dev/null 2>&1; then
		config_array["$field"]="$field_value"
	else
		# 判断 JSON 类型
		local json_type=$(echo "$field_value" | jq -r 'type')
		
		case "$json_type" in
			object)
				# 加载到数组
				while IFS="=" read -r key value; do
					[[ -n "$key" ]] && config_array["$key"]="$value"
				done < <(
					echo "$field_value" | jq -r 'to_entries[] | "\(.key)=\(.value)"'
				)
				;;
			*)
				config_array["$field"]="$field_value"
				;;
		esac
	fi
}

# 执行所有服务
service_loop()
{
	local operation="$1"
	local param="${2:-}"
	
	local failed=0
	local services=()
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		# 检查服务是否启用
		! check_service_enabled "$service" && continue
		
		services+=("$service")
	done
	
	if [[ ${#services[@]} -eq 0 ]]; then
		logger "WARNING" "没有启用的服务需要执行"
		return 0
	fi
	
	for service in "${services[@]}"; do
		# 执行函数
		if ! execute_service_func "$service" "$operation" "$param"; then
			logger "ERROR" "[$operation] 服务 $service 执行失败"
			failed=1
		fi
	done
	
	return $failed
}

# 等待所有服务进程
wait_for_services()
{
	local timeout="${1:-0}"			# 0表示无限等待
	local check_interval="${2:-5}"	# 检查间隔(秒)
	
	local service_pid_array=()
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		# 检查服务是否启用
		! check_service_enabled "$service" && continue
		
		# 检查服务是否存活
		! check_service_alive "$service" && continue
		
		# 获取服务的pid
		local pid=$(get_service_pid "$service" 2>/dev/null)
		[[ -z "$pid" || "$pid" == "null" ]] && continue
		
		service_pid_array+=("$service:$pid")
	done
	
	if [[ ${#service_pid_array[@]} -eq 0 ]]; then
		logger "WARNING" "没有需要等待的服务进程"
		return 0
	fi
	
	local exit_code=0
	local start_time=$(date +%s)
	
	# 等待循环
	while true; do
		local new_array=()
		local alive_count=0
		
		for entry in "${service_pid_array[@]}"; do
			IFS=':' read -r service pid <<< "$entry"
			
			# 检查服务是否存活
			if check_service_alive "$service" "$pid"; then
				new_array+=("$entry")
				alive_count=$((alive_count + 1))
			else
				# 服务已退出
				logger "INFO" "服务 $service 已退出 (PID=$pid)"
				exit_code=1	# 标记有进程异常退出
				
				# 清理状态
				set_service_field "$service" "state.pid" "null"
				set_service_field "$service" "state.status" "stopped"
			fi
		done
		
		service_pid_array=("${new_array[@]}")
		
		# 全部退出
		[[ $alive_count -eq 0 ]] && {
			logger "INFO" "所有服务进程已退出"
			break
		}
		
		# 超时判断
		if [[ "$timeout" -gt 0 ]]; then
			local now=$(date +%s)
			local elapsed=$((now - start_time))
			
			if [[ $elapsed -ge $timeout ]]; then
				exit_code=124
				logger "WARNING" "等待服务退出超时 (${timeout}s)"
				break
			fi
		fi
		
		sleep "$check_interval"
	done
	
	return $exit_code
}

# 设置服务
set_service_env()
{
	# 设置系统用户
	set_service_user
	
	if [ "$1" = "config" ]; then
: <<'COMMENT_BLOCK'
		# 设置SSH服务
		local params=("${SSHD_CONFIG[port]}" "${SSHD_CONFIG[listen]}" "${SSHD_CONFIG[confile]}" "${SSHD_CONFIG[hostkey]}")
		if ! set_ssh_service "${params[@]}"; then
			return 1
		fi
COMMENT_BLOCK

		# 设置 root 用户密码
		echo "root:$ROOT_PASSWORD" | chpasswd
		
		# 设置定时更新任务
		schedule_updates
	fi
}

# 初始化服务
init_service()
{
	# 设置服务
	if ! set_service_env "$1"; then
		return 1
	fi
}

# 运行服务
run_service()
{
	# 启动 SSH 服务
	if [ -x /usr/sbin/sshd ] && ! pgrep -x sshd > /dev/null; then
		logger "INFO" "正在启动服务sshd..."
		
		mkdir -p /run/sshd 2>/dev/null
		touch "${SSHD_CONFIG[logfile]}"

		#nohup /usr/sbin/sshd -D -e "$@" > /var/log/sshd.log 2>&1 &
		/usr/sbin/sshd -e "$@" -E "${SSHD_CONFIG[logfile]}"
	fi
}

# 停止服务
close_service()
{
	if pgrep -x "sshd" > /dev/null; then
		logger "INFO" "sshd服务即将关闭中..." "close_service" "file"
		killall -q "sshd"
	fi
}