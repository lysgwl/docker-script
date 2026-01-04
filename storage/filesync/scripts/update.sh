#!/bin/bash

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh || exit 1

# 更新日志
update_log()
{
	local level="$1"
	local message="${2:-}"
	local log_file="${3:-${SYSTEM_CONFIG[update_log]}}"
	
	if [[ "$level" == "START_TITLE" || "$level" == "END_TITLE" ]]; then
		print_title "$log_file"
		print_log "TEXT" "$message" "" "$log_file"
		print_title "$log_file"
	else
		print_log "$level" "$message" "" "$log_file"
	fi
}

# 展示更新状态汇总
_show_status_summary()
{
	update_log "SUBTITLE" "服务更新状态汇总"
	
	# 按服务名称排序
	local sorted_services=$(echo "${!SERVICE_STATES[@]}" | tr ' ' '\n' | sort)
	
	for service in $sorted_services; do
		# 获取服务状态
		local status=$(get_service_status "$service")
		local reason=$(get_service_reason "$service")
		
		local status_display=""
		case "$status" in
			"${SERVICE_STATUS[SUCCESS]}")
				status_display="✅ $reason" ;;
			"${SERVICE_STATUS[FAILURE]}")
				status_display="❌ $reason" ;;
			"${SERVICE_STATUS[EXECUTING]}")
				status_display="🔄 $reason" ;;
			"${SERVICE_STATUS[DISABLED]}")
				status_display="⚪ $reason" ;;
			*)
				status_display="⚪ $status ($reason)" ;;
		esac
		
		update_log "TEXT" "  $(printf "%-15s" "$service") : $status_display"
	done
}

# 展示更新统计
_show_update_reporter()
{
	local duration="$1"
	update_log "SUBTITLE" "更新统计"
	
	local total_count=0
	local success_count=0
	local failure_count=0
	
	for service in "${!SERVICE_STATES[@]}"; do
		! check_service_enabled "$service" && continue
		
		((total_count++))
		
		local status=$(get_service_status "$service")
		case "$status" in
			"${SERVICE_STATUS[SUCCESS]}")
				((success_count++)) ;;
			"${SERVICE_STATUS[FAILURE]}")
				((failure_count++)) ;;
		esac
	done
	
	update_log "TEXT" "  服务总数: ${#SERVICE_STATES[@]}"
	update_log "TEXT" "  成功数量: $success_count"
	update_log "TEXT" "  失败数量: $failure_count"
	update_log "TEXT" "  执行耗时: $duration"
}

# 更新执行器
_update_executor()
{
	local total_count=${#SERVICE_STATES[@]}
	if [[ $total_count -eq 0 ]]; then
		update_log "WARNING" "未检测到服务配置, 请检查!"
		return 1
	fi
	
	update_log "SECTION" "执行服务更新" >&2
	
	# 先统计启用的服务数量
	local enabled_count=0
	for service in "${!SERVICE_STATES[@]}"; do
		check_service_enabled "$service" && ((enabled_count++))
	done
	
	if [[ $enabled_count -eq 0 ]]; then
		update_log "INFO" "ℹ️ 服务总数：${total_count}, 无启用服务需要更新!" >&2
		return 2
	fi
	
	local overall_success=true
	
	local service_index=0
	local updated_count=0
	local skipped_count=0
	
	for service in "${!SERVICE_STATES[@]}"; do
		((service_index++))
		
		# 未启用直接跳过
		if ! check_service_enabled "$service"; then
			update_service_status "$service" "${SERVICE_STATUS[DISABLED]}" "未启用"
			update_log "INFO" "[$service_index/$total_count] 服务 $service 未启用, 跳过更新检查" >&2
			continue
		fi
		
		# 跳过更新检查
		if ! check_service_updated "$service"; then
			update_service_status "$service" "${SERVICE_STATUS[SKIPPED]}" "跳过更新"
			update_log "INFO" "[$service_index/$total_count] 服务 $service 更新未开启, 跳过更新检查" >&2
			
			((skipped_count++))
			continue
		fi
		
		# 需要更新的服务
		((updated_count++))
		
		update_service_status "$service" "${SERVICE_STATUS[EXECUTING]}" "处理更新"
		update_log "INFO" "正在更新服务 [$updated_count/$total_count]: $service" >&2
		
		# 执行服务更新
		if execute_service_func "$service" "update"; then
			update_service_status "$service" "${SERVICE_STATUS[SUCCESS]}" "更新成功"
			update_log "INFO" "服务 $service 更新成功" >&2
		else
			update_service_status "$service" "${SERVICE_STATUS[FAILURE]}" "更新失败"
			update_log "INFO" "服务 $service 更新失败" >&2
			overall_success=false
		fi
	done
	
	# 显示汇总信息
	#update_log "SUBTITLE" "更新检查结果" >&2
	#update_log "INFO" "总服务数: $total_count" >&2
	#update_log "INFO" "已启用: $enabled_count" >&2
	#update_log "INFO" "未启用: $((total_count - enabled_count))" >&2
	#update_log "INFO" "实际处理: $updated_count" >&2
	
	if [[ "$overall_success" == "false" ]]; then
		update_log "WARNING" "⚠️ 部分服务更新失败" >&2
		return 3
	fi
	
	local processed_count=$((updated_count + skipped_count))
	if [[ $processed_count -eq $enabled_count ]]; then
		update_log "INFO" "✅ 完成处理${processed_count}/${enabled_count}服务" >&2
	else
		update_log "INFO" "ℹ️ 服务总数 ${total_count}:已更新 ${updated_count},未处理 $((enabled_count - processed_count ))" >&2
	fi
	
	return 0
}

# 结果报告器
_result_reporter() 
{
	local duration="$1"
	local overall_success="$2"
	
	# 展示更新状态
	_show_status_summary
	
	# 展示更新统计
	_show_update_reporter "$duration"
	
	# 显示总体结果
	if [[ "$overall_success" == "true" ]]; then
		update_log "INFO" "🎉 所有服务更新成功"
	else
		update_log "WARNING" "⚠️ 部分服务更新失败"
	fi
}

# 更新业务模块
update_modules()
{
	# 检查更新锁
	! lock_manager "check" "$UPDATE_LOCK" && return 0 
	
	# 创建更新锁
	! lock_manager "create" "$UPDATE_LOCK" && return 1
	
	# 清除更新锁
	trap 'lock_manager "remove" "$UPDATE_LOCK"' EXIT
	
	# 加载服务状态
	load_service_states
	
	# 记录开始
	local start_time=$(time_manager "start")
	
	update_log "BLANK"
	update_log "START_TITLE" "# 服务更新开始 $(date +"%Y-%m-%d %H:%M:%S") (用户: ${USER_CONFIG[user]}) #"
	
	# 执行更新
	_update_executor
	
	local result=$?
	if [[ $result =~ ^[03]$ ]]; then
		local overall_success=$([[ $result -eq 0 ]] && echo true || echo false)
		
		# 计算耗时
		local duration=$(time_manager "calculate" "$start_time")
		
		# 报告结果
		_result_reporter "$duration" "$overall_success"
	fi
	
	update_log "END_TITLE" "# 服务更新结束 $(date +"%Y-%m-%d %H:%M:%S") #"
	update_log "BLANK"

	# 返回结果
	[[ $result =~ ^[01]$ ]]
}

# 设置定时更新任务
schedule_updates()
{
	print_log "TRACE" "设置定时更新检查任务"
	
	# 默认配置
	local default_schedule="0 3 * * 0"
	local schedule=${UPDATE_CHECK_SCHEDULE:-$default_schedule}
	
	if [[ $(echo "$schedule" | wc -w) -ne 5 ]]; then
		print_log "ERROR" "cron表达式格式不正确, 请检查!"
		return
	fi
	
	if ! [[ "$schedule" =~ ^([0-9*/,\-]+[[:space:]]+){4}[0-9*/,\-]+$ ]]; then
		print_log "ERROR" "cron表达式包含无效字符, 请检查!"
		return 1
	fi
	
	# 检查 dcron
	local cron_file="/etc/crontabs/root"
	if [[ ! -f "$cron_file" ]]; then
		print_log "ERROR" "cron 配置文件不存在, 请检查!"
		return
	fi
	
	# 脚本路径
	local run_script="${BASH_SOURCE[0]}"
	
	# 检查任务
	if ! grep "$run_script" "$cron_file" > /dev/null 2>&1; then
		echo "$schedule $run_script" >> "$cron_file"
	fi

	print_log "TRACE" "完成设置定时任务"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# 更新业务模块
	update_modules
	
	# 执行业务模块
	exec_as_user ${USER_CONFIG[user]} "
		run_modules
	" &
	
	wait $!
fi