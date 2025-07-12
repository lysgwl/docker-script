#!/bin/bash
set -eo pipefail

# 获取工作目录
WORK_DIR="${WORK_DIR:-/app}"

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh

# 更新服务
update_service()
{
	local service_name=$1
	local update_func=$2
	
	service_status[$service_name]="进行中"
	
	if $update_func; then
		service_status[$service_name]="✅ 成功"
	else
		service_status[$service_name]="❌ 失败"
		overall_success=false
	fi
}

# 更新模块
update_modules()
{
	# echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - $WORK_DIR" >> /var/log/test.log
	
	# 检查是否已有更新进行中
	if [ -f "$RUN_UPDATE_LOCK" ]; then
		echo "[WARNING] 更新已在进行中，跳过本次更新" >> "$RUN_UPDATE_LOG"
		return 0
	fi
	
	# 创建锁文件
	touch "$RUN_UPDATE_LOCK" || {
		echo "[ERROR] 无法创建锁文件: $RUN_UPDATE_LOCK" >> "$RUN_UPDATE_LOG"
		return 1
	}
	
	# 初始化状态
	local overall_success=true
	local -A service_status=(
		["filebrowser"]="未执行"
		["openlist"]="未执行"
		["syncthing"]="未执行"
	)
	
	# 更新开始
	local start_time=$(date +%s)
	echo "================= [$(date '+%Y-%m-%d %H:%M:%S')] 开始自动更新 =================" >> "$RUN_UPDATE_LOG"
	
	# 执行更新
	update_service "filebrowser" update_filebrowser_service
	update_service "openlist" update_openlist_service
	update_service "syncthing" update_syncthing_service
	
	# 计算耗时
	local end_time=$(date +%s)
	local duration=$((end_time - start_time))
	
	# 更新状态
	echo "" >> "$RUN_UPDATE_LOG"
	for service in "${!service_status[@]}"; do
		printf "%-15s: %s\n" "$service" "${service_status[$service]}" >> "$RUN_UPDATE_LOG"
	done
	
	echo "" >> "$RUN_UPDATE_LOG"
	echo "[耗时] ${duration} 秒" >> "$RUN_UPDATE_LOG"
	
	# 清理锁文件
	trap 'rm -f "$RUN_UPDATE_LOCK"' EXIT
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
	
	# 脚本替换
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