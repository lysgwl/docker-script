#!/bin/bash

set -eo pipefail

# 工作目录
readonly WORK_DIR=$(pwd)

# 定时计划
readonly UPDATE_CHECK_SCHEDULE="*/2 * * * *"

# 首次运行标识
readonly RUN_FIRST_LOCK="/var/run/first_run_flag.pid"

# 定义系统配置数组
declare -A system_config=(
	["downloads_dir"]="${WORK_DIR}/downloads"		# 下载目录
	["install_dir"]="${WORK_DIR}/install"			# 安装目录
	["conf_dir"]="${WORK_DIR}/config"				# 预配置目录
	["config_dir"]="/config"						# 配置目录
	["data_dir"]="/data"							# 数据目录
	["usr_dir"]="/mnt/usr"							# 用户目录
	["arch"]="$(uname -m)"							# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"		# 系统类型
)

readonly -A system_config

umask ${UMASK:-022}

# 加载 feature 脚本
source $WORK_DIR/scripts/feature.sh

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载 alist 脚本
source $WORK_DIR/scripts/set_alist.sh

# 加载 openlist 脚本
source $WORK_DIR/scripts/set_openlist.sh

# 加载 syncthing 脚本
source $WORK_DIR/scripts/set_syncthing.sh

# 加载 filebrowser 脚本
source $WORK_DIR/scripts/set_filebrowser.sh

# 初始化模块
init_modules()
{
	echo "[WARNING] init 当前用户:$(id -un), UID:$(id -u), UMASK:$(umask)"
	
	if [ "$(id -u)" -ne 0 ]; then
		echo "[ERROR] 非root用户权限无法初始环境, 请检查!"
		return 1
	fi
	
	local param=$1
	[ "$param" = "run" ] && param="config"
	
	# 初始服务环境
	if ! init_service "$param"; then
		return 1
	fi
	
	# 初始 alist 环境
	#if ! init_alist_service "$param"; then
	#	return 1
	#fi
	
	# 初始 openlist 环境
	if ! init_openlist_service "$param"; then
		return 1
	fi
	
	# 初始 syncthing 环境
	if ! init_syncthing_service "$param"; then
		return 1
	fi
	
	# 初始 filebrowser 环境
	if ! init_filebrowser_service "$param"; then
		return 1
	fi
	
	return 0
}

# 运行模块
run_modules()
{
	echo "[WARNING] running 当前用户:$(id -un), UID:$(id -u), UMASK:$(umask)"
	
	# 运行 alist 服务
	#run_alist_service
	
	# 运行 openlist 服务
	run_openlist_service

	# 运行 syncthing 服务
	run_syncthing_service
	
	# 运行 filebrowser 服务
	run_filebrowser_service
}

# 更新模块
update_modules()
{
	# 更新 filebrowser
	update_filebrowser_service
}

# 关闭模块
close_modules()
{
	# 关闭 alist 服务
	#close_alist_service
	
	# 关闭 openlist 服务
	close_openlist_service
	
	# 关闭 syncthing 服务
	close_syncthing_service
	
	# 关闭 filebrowser 服务
	close_filebrowser_service
}

# 设置定时更新任务
schedule_updates()
{
	echo "[INFO] 设置定时更新检查任务..."
	
	# 默认配置
	local DEFAULT_SCHEDULE="0 3 * * 0"
	local SCHEDULE=${UPDATE_CHECK_SCHEDULE:-$DEFAULT_SCHEDULE}
	
	if [[ $(echo "$SCHEDULE" | wc -w) -ne 5 ]] || 
	   ! [[ "$SCHEDULE" =\~ ^([0-9*/,-]+[[:space:]]+){4}[0-9*/,-]+$ ]]; then
		echo "[WARNING] cron表达式字段不符合要求, 请检查!"
		return
	fi
	
	# 脚本替换
	local run_script="$0"

	(
		# 初始计算
		local run_sec=$(get_next_cron_time "$SCHEDULE")
	
		while true; do
			# 计算当前时间
			local now_sec=$(date +%s)
			
			# 计算需要等待的秒数
			local wait_seconds=$((run_sec - now_sec))
			
			# 如果已经过了执行时间，立即执行
			if [[ $wait_seconds -lt 0 ]]; then
				wait_seconds=0
			fi
			
			# 等待到目标时间
			if [[ $wait_seconds -gt 0 ]]; then
				sleep $wait_seconds
			fi
			
			# 执行更新检查
			#$run_script update
			
			# 计算下一次执行时间
			run_sec=$(get_next_cron_time "$SCHEDULE")
		done
	) &
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then

	if [[ ! -f "${RUN_FIRST_LOCK}" ]]; then
		echo "===== 初始化阶段（$1）====="
		
		if ! init_modules "$1"; then
			exit 1
		fi
		
		# 设置定时更新任务
		# schedule_updates
		
		touch "${RUN_FIRST_LOCK}"
	fi	
	
	if [ "$1" = "run" ]; then
		echo "===== 启动服务阶段 ====="

		# 捕获 SIGTERM 信号
		trap close_modules SIGTERM
		
		# 执行模块
		su-exec ${user_config[user]}:${user_config[group]} bash -c "
			source /app/scripts/entrypoint.sh
			run_modules
		" &
		
		wait $!
		
		# 保持容器运行
		tail -f /dev/null
	fi
	
	if [ "$1" = "run" ]; then
		echo "===== 更新服务阶段 ====="
		update_modules
	fi
fi