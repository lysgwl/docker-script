#!/bin/bash
set -eo pipefail

# 获取工作目录
WORK_DIR="${WORK_DIR:-/app}"

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载 openlist 脚本
source $WORK_DIR/scripts/set_openlist.sh

# 加载 syncthing 脚本
source $WORK_DIR/scripts/set_syncthing.sh

# 加载 filebrowser 脚本
source $WORK_DIR/scripts/set_filebrowser.sh

# 更新模块
update_modules()
{
	# echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - $WORK_DIR" >> /var/log/test.log
	
	if [ ! -f "$RUN_UPDATE_LOCK" ]; then
		touch "$RUN_UPDATE_LOCK"
		
		# 更新 filebrowser
		if ! update_filebrowser_service; then
			rm -rf "$RUN_UPDATE_LOCK"
		fi
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
		echo "===== 更新服务阶段 ====="
		update_modules
	fi
fi