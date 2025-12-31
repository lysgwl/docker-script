#!/bin/bash
set -eo pipefail

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh || exit 1

# 执行服务更新
_execute_update()
{
	local -n status_array_var=$1
	
	local updated_count=0
	local total_count=${#status_array[@]}
	
	local overall_success=true
	for service in "${!SERVICE_ENABLED[@]}"; do
		[[ -z "${status_array_var[$service]:-}" ]] && continue
		
		# 设置运行状态
		status_array_var["$service"]="进行中"
		
		((updated_count++))
		
		# 显示当前进度
		print_log "INFO" "正在更新服务 $service: [$updated_count/$total_count]" "${SYSTEM_CONFIG[update_log]}"
		
		# 执行服务更新
		if execute_service_function "$service" "update"; then
			status_array_var["$service"]="✅ 成功"
			print_log "INFO" "$service 更新成功" "${SYSTEM_CONFIG[update_log]}"
		else
			status_array_var["$service"]="❌ 失败"
			
			overall_success=false
			print_log "INFO" "$service 更新失败" "${SYSTEM_CONFIG[update_log]}"
		fi
	done
	
	[[ "$overall_success" == "true" ]] && return 0 || return 1
}

# 更新执行器
_update_executor()
{
	local -n status_array_ref=$1
	
	print_section "执行服务更新" "${SYSTEM_CONFIG[update_log]}"
	print_log "INFO" "开始执行服务更新..."

	# 初始化服务状态
	init_service_status status_array_ref
	
	# 执行服务更新
	if ! _execute_update status_array_ref; then
		print_log "WARNING" "部分服务更新操作失败, 请检查!" "${SYSTEM_CONFIG[update_log]}"
		return 1
	fi
	
	print_log "INFO" "所有服务更新操作完成!" "${SYSTEM_CONFIG[update_log]}"
}

# 结果报告器
_result_reporter() 
{
	local duration="$1"
	local overall_success="$2"
	local -n status_array_ref="$3"
	
	# 显示状态汇总
	print_section "业务更新状态汇总:" "${SYSTEM_CONFIG[update_log]}"
	show_service_status status_array
	return
	
	# 显示统计信息
	update_log "DIVIDER" ""
	update_log "SECTION" "更新统计"
	
	local summary=$(get_service_status status_array)
	local total_count=$(echo "$summary" | cut -d: -f1)
	local success_count=$(echo "$summary" | cut -d: -f2)
	local failure_count=$(echo "$summary" | cut -d: -f3)
	
	echo "  服务总数: $total_count" >> "$RUN_UPDATE_LOG"
	echo "  成功数量: $success_count" >> "$RUN_UPDATE_LOG"
	echo "  失败数量: $failure_count" >> "$RUN_UPDATE_LOG"
	echo "  执行耗时: $duration" >> "$RUN_UPDATE_LOG"
	
	update_log "DIVIDER" ""
	
	# 显示总体结果
	if [[ "$overall_success" == "true" ]]; then
		update_log "INFO" "🎉 所有服务更新成功"
	else
		update_log "WARNING" "⚠️  部分服务更新失败 (失败: $failure_count/$total_count)"
	fi
}

# 更新业务模块
update_modules()
{
	# 检查更新锁
	[[ ! lock_manager "check" "$UPDATE_LOCK" ]] && return 0
	
	# 创建更新锁
	[[ ! lock_manager "create" "$UPDATE_LOCK" ]] && return 1
	
	# 清除更新锁
	trap 'lock_manager "remove" "$UPDATE_LOCK"' EXIT
	
	declare -gA service_status=()
	print_header "开始自动更新" "${SYSTEM_CONFIG[update_log]}"
	
	# 记录开始
	local start_time=$(time_manager "start")
	
	# 执行更新
	local overall_success=$(_update_executor service_status && echo "true" || echo "false")
	
	# 计算耗时
	local duration=$(time_manager "calculate" "$start_time")
	
	# 报告结果
	_result_reporter "$duration" "$overall_success" service_status
	print_header "完成业务更新"$'\n' "${SYSTEM_CONFIG[update_log]}"
	
	# 返回结果
	[[ "$overall_success" == "true" ]] && return 0 || return 1
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
	print_section "更新服务 (${USER_CONFIG[user]})" "${SYSTEM_CONFIG[update_log]}"
	
	# 更新业务模块
	update_modules
	
	# 执行业务模块
	exec_as_user ${USER_CONFIG[user]} "
		run_modules
	" &
	
	wait $!
fi