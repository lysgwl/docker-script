#!/bin/bash
set -eo pipefail

# 获取工作目录
WORK_DIR="${WORK_DIR:-/app}"

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh

#更新日志
update_log()
{
	local level="$1"
	local message="$2"
	local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	
	case "$level" in
		"INFO")
			echo "[INFO] $timestamp $message" >> "$RUN_UPDATE_LOG"
			;;
		"WARNING") 
			echo "[WARNING] $timestamp $message" >> "$RUN_UPDATE_LOG"
			;;
		"ERROR")
			echo "[ERROR] $timestamp $message" >> "$RUN_UPDATE_LOG"
			;;
		"SECTION")
			echo "=== $message ===" >> "$RUN_UPDATE_LOG"
			;;
		"HEADER")
			echo "================= $message =================" >> "$RUN_UPDATE_LOG"
			;;
		"DIVIDER")
			echo "------------------------------------------------------------" >> "$RUN_UPDATE_LOG"
			;;
	esac
}

# 锁文件管理
lock_manager() 
{
	local action="$1"
	
	case "$action" in
		"check")
			if [ -f "$RUN_UPDATE_LOCK" ]; then
				update_log "WARNING" "更新已在进行中，跳过本次更新"
				return 1
			fi
			
			return 0
			;;
		"create")
			touch "$RUN_UPDATE_LOCK" || {
				update_log "ERROR" "无法创建锁文件: $RUN_UPDATE_LOCK"
				return 1
			}
			;;
		"remove")
			rm -f "$RUN_UPDATE_LOCK"
			;;
	esac
}

# 时间管理
time_manager() 
{
	local action="$1"
	local value="${2:-}"
	
	case "$action" in
		"start")
			echo $(date +%s)
			;;
		"calculate")
			local start_time=$value
			local end_time=$(date +%s)
			local duration=$((end_time - start_time))
			local minutes=$((duration / 60))
			local seconds=$((duration % 60))
			
			if [[ $minutes -gt 0 ]]; then
				echo "${minutes}分${seconds}秒"
			else
				echo "${duration}秒"
			fi
			;;
	esac
}

# 初始化服务状态
init_service_status()
{
	local -n status_ref=$1
	
	# 清空数组
	status_ref=()
	
	for service in "${!service_enabled[@]}"; do
		if check_service_enabled "$service"; then
			status_ref["$service"]="未执行"
		fi
	done
}

# 获取服务状态
get_service_status()
{
	local -n status_ref=$1
	
	local success_count=0
	local failure_count=0
	local total_count=0
	
	for service in "${!status_ref[@]}"; do
		((total_count++))
		case "${status_ref[$service]}" in
			*成功*) ((success_count++)) ;;
			*失败*) ((failure_count++)) ;;
		esac
	done
	
	echo "$total_count:$success_count:$failure_count"
}

# 显示服务状态
show_service_status()
{
	local -n status_ref=$1
	
	update_log "SECTION" "服务更新状态汇总"
	
	for service in "${!status_ref[@]}"; do
		printf "  %-15s: %s\n" "$service" "${status_ref[$service]}" >> "$RUN_UPDATE_LOG"
	done
}

# 更新执行器
update_executor()
{
	local -n status_array=$1
	
	# 更新开始日志
	update_log "SECTION" "执行服务更新"
	update_log "INFO" "开始执行服务更新..."
	
	# 初始化状态
	init_service_status status_array
	
	# 执行更新操作
	local overall_success=true
	local total_count=${#status_array[@]}
	local updated_count=0
	
	for service in "${!service_enabled[@]}"; do
		if [[ -z "${status_array[$service]:-}" ]]; then
			continue
		fi
		
		# 设置运行状态
		status_array["$service"]="进行中"
		
		((updated_count++))
		
		# 显示当前进度
		update_log "INFO" "正在更新服务 [$updated_count/$total_count]: $service"
		
		# 执行服务更新
		if execute_service_function "$service" "update"; then
			status_array["$service"]="✅ 成功"
			update_log "INFO" "$service 更新成功"
		else
			status_array["$service"]="❌ 失败"
			update_log "WARNING" "$service 更新失败"
			
			overall_success=false
		fi
	done
	
	# 更新完成日志
	if [[ "$overall_success" == "true" ]]; then
		update_log "INFO" "所有服务更新操作完成"
	else
		update_log "WARNING" "部分服务更新操作失败"
	fi
	
	# 返回结果
	if [[ "$overall_success" == "true" ]]; then
		return 0
	else
		return 1
	fi
}

# 结果报告器
result_reporter() 
{
	local -n status_array=$1
	local duration=$2
	local overall_success=$3
	
	# 显示状态汇总
	show_service_status status_array
	
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

# 更新模块
update_modules()
{
	# 检查锁状态
	if ! lock_manager "check"; then
		return 0
	fi
	
	# 创建锁文件
	if ! lock_manager "create"; then
		return 1
	fi
	
	# 确保锁文件被清理
	trap 'lock_manager "remove"' EXIT
	
	 # 记录开始
	local start_time=$(time_manager "start")
	update_log "HEADER" "开始自动更新"
	update_log "INFO" "工作目录: $WORK_DIR"
	update_log "INFO" "用户: ${user_config[user]}:${user_config[group]}"
	
	# 定义局部状态数组
	declare -gA service_status=()
	
	# 执行更新并获取结果
	local overall_success
	if update_executor service_status; then
		overall_success="true"
	else
		overall_success="false"
	fi
	
	# 计算耗时
	local duration=$(time_manager "calculate" "$start_time")
	
	# 生成报告
	result_reporter service_status "$duration" "$overall_success"
	
	# 记录结束
	update_log "HEADER" "更新完成"
	echo "" >> "$RUN_UPDATE_LOG"
	
	if [[ "$overall_success" == "true" ]]; then
		return 0
	else
		return 1
	fi
}

# 设置定时更新任务
schedule_updates()
{
	echo "[INFO] 设置定时更新检查任务..."
	
	# 默认配置
	local default_schedule="0 3 * * 0"
	local schedule=${UPDATE_CHECK_SCHEDULE:-$default_schedule}
	
	if [[ $(echo "$schedule" | wc -w) -ne 5 ]]; then
		echo "[ERROR] cron表达式必须有5个字段" >&2
		return
	fi
	
	if ! [[ "$schedule" =~ ^([0-9*/,\-]+[[:space:]]+){4}[0-9*/,\-]+$ ]]; then
		echo "[ERROR] cron表达式包含无效字符" >&2
		return 1
	fi
	
	# 脚本路径
	local run_script="$WORK_DIR/scripts/update.sh"

	# 检查 dcron
	local cron_file="/etc/crontabs/root"
	if [[ ! -f "$cron_file" ]]; then
		echo "[ERROR] cron 配置文件不存在, 请检查!"
		return
	fi
	
	# 检查任务
	if ! grep "$run_script update" "$cron_file" > /dev/null 2>&1; then
		echo "$schedule $run_script update" >> "$cron_file"
	fi

	echo "[INFO] 完成设置定时任务..."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	if [ "$1" = "update" ]; then
		echo "===== ${user_config[user]}:${user_config[group]} 更新服务阶段 =====" >> "$RUN_UPDATE_LOG"
		update_modules
		
		# 执行模块
		su-exec ${user_config[user]}:${user_config[group]} bash -c "
			source \"$WORK_DIR/scripts/common.sh\"
			run_modules
		" &
		
		wait $!
	fi
fi