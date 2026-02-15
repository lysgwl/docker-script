#!/bin/bash

# 获取服务配置
get_service_config()
{
	local service="$1"
	local field="${2:-config}"
	local ref_name="${3:-SERVICE_CONFIG}"
	
	# 获取配置JSON
	local field_value
	field_value=$(get_service_field "$service" "$field" 2>/dev/null)
	
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
execute_services_action()
{
	local action="$1"
	local param="${2:-}"
	
	local failed=0
	local services=()
	
	for service in "${!SERVICE_REGISTRY[@]}"; do
		# 检查服务是否启用
		if ! check_service_enabled "$service"; then
			#update_service_states "$service" "${SERVICE_STATUS[DISABLED]}" "未启用"
			continue
		fi
		
		services+=("$service")
	done
	
	if [[ ${#services[@]} -eq 0 ]]; then
		logger "WARNING" "没有启用的服务需要执行"
		return 0
	fi
	
	for service in "${services[@]}"; do
		# 执行函数
		if ! execute_service_func "$service" "$action" "main" "$param"; then
			logger "ERROR" "[$action] 服务 $service 执行失败"
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
	
	local start_time=$(date +%s)
	local exit_code=0
	
	# 等待循环
	while true; do
		local pending_count=0
		
		for service in "${!SERVICE_REGISTRY[@]}"; do
			# 检查服务是否启用
			! check_service_enabled "$service" && continue
		
			# 获取服务的操作状态
			local action=$(get_service_action "$service")
		
			# 获取服务的pid
			local pid=$(get_service_pid "$service" 2>/dev/null)
			
			# 检查服务存活
			if [[ -n "$pid" ]] && check_service_alive "$service" "$pid"; then
				pending_count=$((pending_count + 1))
				continue
			fi
			
			# 进程退出, 检查操作状态
			case "$action" in
				"${SERVICE_ACTIONS[UPDATE]}")
					logger "INFO" "服务 $service 更新操作中, 忽略进程退出"
					pending_count=$((pending_count + 1))
					#update_service_pid "$service" "null"
					;;
				"${SERVICE_ACTIONS[RUN]}")
					logger "DEBUG" "[$service] RUN 阶段, 等待进程就绪"
					pending_count=$((pending_count + 1))
					;;
				"${SERVICE_ACTIONS[CLOSE]}")
					logger "INFO" "服务 $service 关闭操作中, 进程退出正常"
					update_service_pid "$service" "null"
					;;
				*)	# 异常退出
					exit_code=1
					logger "ERROR" "服务 $service 服务异常退出 (PID=$pid)"
					
					update_service_pid "$service" "null"
					update_service_states "$service" "${SERVICE_STATUS[FAILURE]}" "进程异常退出"
					;;
			esac
		done
		
		# 服务生命周期结束
		if [[ "$pending_count" -eq 0 ]]; then
			logger "INFO" "所有服务进程已退出"
			break
		fi
		
		# 超时控制
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
	logger "DEBUG" "正在设置目录拥有者(${USER_CONFIG[user]}:${USER_CONFIG[group]})"
	chown -R ${USER_CONFIG[user]}:${USER_CONFIG[group]} \
			 "${SYSTEM_CONFIG[downloads_dir]}" \
			 "${SYSTEM_CONFIG[update_dir]}" \
			"${SYSTEM_CONFIG[config_dir]}" \
			"${SYSTEM_CONFIG[data_dir]}"
			
	chown "${USER_CONFIG[user]}:${USER_CONFIG[group]}" \
			"${SYSTEM_CONFIG[usr_dir]}"
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
		logger "INFO" "sshd服务即将关闭中..."
		killall -q "sshd"
	fi
}