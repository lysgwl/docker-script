#!/bin/bash

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh || exit 1

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
	local total=$(get_service_count "total")
	if [[ $total -eq 0 ]]; then
		log_update "TEXT" "[UPDATE] 未检测到服务配置" >&2
		return 1
	fi
	
	log_update "TEXT" "[UPDATE] 服务总数: $total" >&2
	
	# 先统计启用的服务数量
	local enabled=$(get_service_count "enabled")
	if [[ $enabled -eq 0 ]]; then
		log_update "TEXT" "[UPDATE] 无启用服务需要更新" >&2
		return 2
	fi
	
	log_update "TEXT" "[UPDATE] 启用服务: $enabled" >&2
	
	local index=0
	local updated=0
	local skipped=0
	
	local overall_success=true
	for service in "${!SERVICE_REGISTRY[@]}"; do
		((index++))
		
		log_update "SUBTITLE" "[UPDATE] [$index/$total] 🔄 更新服务: $service"
		
		# 未启用直接跳过
		if ! check_service_enabled "$service"; then
			log_update "TEXT" "[UPDATE] ❌  $service: 未启用, 跳过更新" >&2
			((skipped++))
			continue
		fi
		
		# 跳过更新检查
		if ! check_service_updated "$service"; then
			log_update "TEXT" "[UPDATE] ⚠️  $service: 更新未开启, 跳过更新" >&2
			((skipped++))
			continue
		fi
		
		# 需要更新的服务
		((updated++))
		
		# 更新服务
		if ! execute_service_func "$service" "${SERVICE_ACTIONS[UPDATE]}" "update"; then
			log_update "TEXT" "[UPDATE] ⚠️  $service: 更新失败" >&2
			overall_success=false
			continue
		fi
		
		log_update "TEXT" "[UPDATE] ✅  $service: 更新成功" >&2
		
		# 重启服务
		if ! execute_service_func "$service" "${SERVICE_ACTIONS[RUN]}" "update"; then
			log_update "TEXT" "[UPDATE] ❌  $service: 重启失败" >&2
			overall_success=false
			continue
		fi
		
		log_update "TEXT" "[UPDATE] ✅  $service: 重启成功" >&2
	done
	
	# 显示汇总信息
	#log_update "SUBTITLE" "更新检查结果" >&2
	#log_update "TEXT" "[UPDATE] 总服务数: $total" >&2
	#log_update "TEXT" "[UPDATE] 启用服务: $enabled" >&2
	#log_update "TEXT" "[UPDATE] 未启用: $((total - enabled))" >&2
	#log_update "TEXT" "[UPDATE] 实际更新: $updated" >&2
	
	if [[ "$overall_success" == "false" ]]; then
		log_update "TEXT" "[UPDATE] ⚠️ 部分服务更新失败" >&2
		return 3
	fi
	
	local processed=$((updated + skipped))
	if [[ $processed -eq $enabled ]]; then
		log_update "TEXT" "[UPDATE] ✅ 完成处理${processed}/${enabled}服务" >&2
	else
		log_update "TEXT" "[UPDATE] ℹ️ 服务总数 ${total}:已更新 ${updated},未处理 $((enabled - processed ))" >&2
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
	
	log_update "BLANK"
	log_update "SECTION" "服务更新开始"
	log_update "TEXT" "[UPDATE] 用户: ${USER_CONFIG[user]}"
	log_update "TEXT" "[UPDATE] 时间: $(date +"%Y-%m-%d %H:%M:%S")"
	
	# 执行更新
	_update_executor
	
	local result=$?
	if [[ $result =~ ^[03]$ ]]; then
		local overall_success=$([[ $result -eq 0 ]] && echo true || echo false)
		
		# 计算耗时
		local duration=$(time_manager "calculate" "$start_time")
		
		# 报告结果
		#_result_reporter "$duration" "$overall_success"
	fi
	
	logger "END_TITLE" "# 服务更新结束 $(date +"%Y-%m-%d %H:%M:%S") #"
	logger "BLANK"

	# 返回结果
	[[ $result =~ ^[01]$ ]]
}

# 设置定时更新任务
schedule_updates()
{
	logger "INFO" "设置定时更新检查任务"
	
	# 默认配置
	local default_schedule="0 3 * * 0"
	local schedule=${UPDATE_CHECK_SCHEDULE:-$default_schedule}
	
	if [[ $(echo "$schedule" | wc -w) -ne 5 ]]; then
		logger "ERROR" "cron表达式格式不正确, 请检查!"
		return
	fi
	
	if ! [[ "$schedule" =~ ^([0-9*/,\-]+[[:space:]]+){4}[0-9*/,\-]+$ ]]; then
		logger "ERROR" "cron表达式包含无效字符, 请检查!"
		return 1
	fi
	
	# 检查 dcron
	local cron_file="/etc/crontabs/root"
	if [[ ! -f "$cron_file" ]]; then
		logger "ERROR" "cron 配置文件不存在, 请检查!"
		return 2
	fi
	
	# 脚本路径
	local run_script="${BASH_SOURCE[0]}"
	
	# 检查任务
	if ! grep "$run_script" "$cron_file" > /dev/null 2>&1; then
		echo "$schedule $run_script" >> "$cron_file"
	fi

	logger "INFO" "完成设置定时任务"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# 更新业务模块
	update_modules
fi