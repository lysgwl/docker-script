#!/bin/bash
set -eo pipefail

# 导出工作目录
export WORK_DIR="${WORK_DIR:-$(pwd)}"

# 加载 update 脚本
source $WORK_DIR/scripts/update.sh

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
	
	# 运行 openlist 服务
	run_openlist_service

	# 运行 syncthing 服务
	run_syncthing_service
	
	# 运行 filebrowser 服务
	run_filebrowser_service
}

# 关闭模块
close_modules()
{
	# 关闭 openlist 服务
	close_openlist_service
	
	# 关闭 syncthing 服务
	close_syncthing_service
	
	# 关闭 filebrowser 服务
	close_filebrowser_service
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then

	if [[ ! -f "${RUN_FIRST_LOCK}" ]]; then
		echo "===== 初始化阶段（$1）====="
		
		if ! init_modules "$1"; then
			exit 1
		fi
		
		# 设置定时更新任务
		schedule_updates
		
		touch "${RUN_FIRST_LOCK}"
	fi	
	
	if [ "$1" = "run" ]; then
		echo "===== 启动服务阶段 ====="

		# 捕获 SIGTERM 信号
		trap close_modules SIGTERM
		
		# 重新加载cron配置
		crond -l 2 -L /dev/stdout &

		# 执行模块
		su-exec ${user_config[user]}:${user_config[group]} bash -c "
			source /app/scripts/entrypoint.sh
			run_modules
		" &
		
		wait $!
		
		# 保持容器运行
		tail -f /dev/null
	fi
fi