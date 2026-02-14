#!/bin/bash

# 更新状态数组
declare -A UPDATE_RESULTS=()

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh || exit 1

# 展示更新状态汇总
_show_status_summary()
{
	log_update "SUBTITLE" "📋 更新状态汇总"
	
	# 按服务名称排序
	local sorted_services=$(echo "${!UPDATE_RESULTS[@]}" | tr ' ' '\n' | sort)
	
	if [[ -z "$sorted_services" ]]; then
		log_update "TEXT" "  没有服务被处理"
		return
	fi
	
	for service in $sorted_services; do
		local result="${UPDATE_RESULTS[$service]}"
		IFS=':' read -r status reason extra <<< "$result"
		
		local status_display=""
		case "$status" in
			"${SERVICE_STATUS[SUCCESS]}")
				status_display="✅  $reason" ;;
			"${SERVICE_STATUS[FAILURE]}")
				status_display="❌  $reason" ;;
			"${SERVICE_STATUS[SKIPPED]}")
				status_display="⏭️  $reason" ;;
			"${SERVICE_STATUS[DISABLED]}")
				status_display="⚪  $reason" ;;
			"${SERVICE_STATUS[UPDATING]}")
				status_display="🔄  $reason" ;;
			*)
				status_display="⚪  $status ($reason)" ;;
		esac
		
		# 额外信息
		if [[ -n "$extra" ]]; then
			status_display="$status_display ($extra)"
		fi
		
		log_update "TEXT" "  $(printf "%-15s" "$service") : $status_display"
	done
}

# 展示更新统计
_show_update_reporter()
{
	local duration="$1"
	log_update "SUBTITLE" "📊 更新统计"
	
	local total=$(get_service_count "total")
	local enabled=$(get_service_count "enabled")
	local disabled=$((total - enabled))
	
	# 按服务名称排序
	local sorted_services=$(echo "${!UPDATE_RESULTS[@]}" | tr ' ' '\n' | sort)
	
	local success=0
	local failure=0
	local skipped=0
	
	for service in $sorted_services; do
		local result="${UPDATE_RESULTS[$service]}"
		IFS=':' read -r status reason extra <<< "$result"
		
		case "$status" in
			"${SERVICE_STATUS[SUCCESS]}")
				((success++)) ;;
			"${SERVICE_STATUS[FAILURE]}")
				((failure++)) ;;
			"${SERVICE_STATUS[SKIPPED]}")
				((skipped++)) ;;
		esac
	done
	
	log_update "TEXT" "  总数    : $total"
	log_update "TEXT" "  启用    : $enabled"
	log_update "TEXT" "  未启用  : $disabled"
	log_update "TEXT" "  成功    : $success"
	log_update "TEXT" "  失败    : $failure"
	log_update "TEXT" "  跳过    : $skipped"
	log_update "TEXT" "  耗时    : $duration"
}

# 更新执行器 (状态执行者)
_update_executor()
{
	local total=$(get_service_count "total")
	if [[ $total -eq 0 ]]; then
		log_update "TEXT" "[UPDATE] 未检测到服务配置" >&2
		return 1
	fi
	
	log_update "DIVIDER"
	log_update "TEXT" "[UPDATE] 服务总数: $total"
	
	# 先统计启用的服务数量
	local enabled=$(get_service_count "enabled")
	if [[ $enabled -eq 0 ]]; then
		log_update "TEXT" "[UPDATE] 无启用服务需要更新"
		return 2
	fi
	
	local disabled=$((total - enabled))
	log_update "TEXT" "[UPDATE] 启用服务: $enabled"
	log_update "TEXT" "[UPDATE] 未启用: $disabled"
	
	local skipped=0
	local updated_total=0
	local update_success=0
	local update_failed=0
	
	local index=0
	local overall_success=true
	
	# 清空结果数组
	UPDATE_RESULTS=()
	
	# 执行更新操作
	log_update "SUBTITLE" "🔧 执行更新操作"
	for service in "${!SERVICE_REGISTRY[@]}"; do
		((index++))
		
		# 未启用直接跳过
		if ! check_service_enabled "$service"; then
			log_update "TEXT" "  [$index/$total] 🔄 $service ... ⏭️  未启用"
			UPDATE_RESULTS["$service"]="${SERVICE_STATUS[DISABLED]}:服务未启用"
			continue
		fi
		
		# 跳过更新检查
		if ! check_service_updated "$service"; then
			log_update "TEXT" "  [$index/$total] 🔄 $service ... ⏸️  更新未开启"
			UPDATE_RESULTS["$service"]="${SERVICE_STATUS[SKIPPED]}:更新未开启"
			((skipped++))
			continue
		fi
		
		# 需要更新的服务
		((updated_total++))
		
		# 执行更新
		if ! execute_service_func "$service" "${SERVICE_ACTIONS[UPDATE]}" "update"; then
			log_update "TEXT" "  [$index/$total] 🔄 $service ... ❌  失败"
			UPDATE_RESULTS["$service"]="${SERVICE_STATUS[FAILURE]}:更新失败"
			overall_success=false
			((update_failed++))
		else
			log_update "TEXT" "  [$index/$total] 🔄 $service ... ✅  成功"
			UPDATE_RESULTS["$service"]="${SERVICE_STATUS[UPDATING]}:更新成功"
			((update_success++))
		fi
	done
	
	local restart_success=0
	local restart_failed=0
	
	index=0
	local restart_total=$((update_success + update_failed))
	
	# 执行重启操作
	log_update "SUBTITLE" "🚀 执行重启操作"
	
	if [[ $update_success -eq 0 && $update_failed -gt 0 ]]; then
		log_update "TEXT" "  (更新失败，无服务可重启)"
	elif [[ $update_success -eq 0 && $update_failed -eq 0 ]]; then
		log_update "TEXT" "  (无服务需要重启)"
	else
		for service in "${!SERVICE_REGISTRY[@]}"; do
			! check_service_enabled "$service" && continue
			! check_service_updated "$service" && continue
			
			((index++))
			
			# 重启服务
			if ! execute_service_func "$service" "${SERVICE_ACTIONS[RUN]}" "update"; then
				log_update "TEXT" "  [$index/$restart_total] 🔄 $service ... ❌  失败"
				UPDATE_RESULTS["$service"]="${SERVICE_STATUS[FAILURE]}:重启失败"
				overall_success=false
				((restart_failed++))
			else
				log_update "TEXT" "  [$index/$restart_total] 🔄 $service ... ✅  成功"
				UPDATE_RESULTS["$service"]="${SERVICE_STATUS[SUCCESS]}:更新完成"
				((restart_success++))
			fi
		done
	fi
	
	# 显示汇总信息
	#log_update "SUBTITLE" "📊 更新统计"
	#log_update "TEXT" "  总服务数: $total"
	#log_update "TEXT" "  启用服务: $enabled"
	#log_update "TEXT" "  未启用: $enabled"
	#log_update "TEXT" "  实际更新: $updated"
	
	if [[ "$overall_success" == "false" ]]; then
		log_update "TEXT" "[UPDATE] ⚠️  更新完成, 部分操作失败"
	else
		log_update "TEXT" "[UPDATE] ✅  所有操作成功完成"
	fi
	
	local updated_total=$((update_success + update_failed))		# 实际更新的服务数
	local processed=$((updated_total + skipped))				# 已处理的服务数
	
	log_update "TEXT" "[UPDATE] 更新: $updated_total, 成功: $update_success, 失败: $update_failed, 跳过: $skipped, 未启用: $disabled"
	
	# 返回状态
	[[ "$overall_success" == "false" ]] && return 3 || return  0
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
		log_update "INFO" " 🎉  所有服务更新成功"
	else
		log_update "WARNING" " ⚠️  部分服务更新失败"
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
	load_service_states "${USER_CONFIG[user]}" "${USER_CONFIG[group]}"
	
	# 记录开始
	local start_time=$(time_manager "start")
	
	log_update "BLANK"
	log_update "START_TITLE" "📦  服务更新开始"
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
		_result_reporter "$duration" "$overall_success"
	fi
	
	log_update "TITLE"
	log_update "BLANK"

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
