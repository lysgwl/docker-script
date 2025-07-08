#!/bin/bash

set -eo pipefail

# 工作目录
readonly WORK_DIR=$(pwd)

# 首次运行标识
readonly RUN_FIRST_LOCK="/var/run/first_run_flag.pid"

# 定义系统配置数组
declare -A system_config=(
	["downloads_dir"]="$WORK_DIR/downloads"		# 下载目录
	["install_dir"]="$WORK_DIR/install"			# 安装目录
	["conf_dir"]="$WORK_DIR/config"				# 预配置目录
	["config_dir"]="/config"					# 配置目录
	["data_dir"]="/data"						# 数据目录
)

readonly -A system_config

umask ${UMASK:-022}

# 加载feature脚本
source ${WORK_DIR}/scripts/feature.sh

# 加载服务脚本
source ${WORK_DIR}/scripts/set_service.sh

# 加载 freeswitch 脚本
source ${WORK_DIR}/scripts/set_freeswitch.sh

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
	
	# 初始 freeswitch 环境
	if ! init_freeswitch_service "$param"; then
		return 1
	fi
	
	return 0
}

# 运行模块
run_modules()
{
	echo "[WARNING] running 当前用户:$(id -un), UID:$(id -u), UMASK:$(umask)"
	
	# 运行 freeswitch 服务
	run_freeswitch_service
}

# 关闭模块
close_modules()
{
	# 关闭 freeswitch 服务
	close_freeswitch_service
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then

	if [[ ! -f "${RUN_FIRST_LOCK}" ]]; then
		echo "===== 初始化阶段（$1）====="
		
		if ! init_modules "$1"; then
			exit 1
		fi
		
		touch "${RUN_FIRST_LOCK}"
	fi
	
	if [ "$1" = "run" ]; then
		echo "===== 启动服务阶段 ====="
		
		# 捕获 SIGTERM 信号
		trap close_modules SIGTERM
		
		# 执行模块
		gosu ${user_config[user]}:${user_config[group]} bash -c "
			source /app/scripts/entrypoint.sh
			run_modules
		" &
		
		wait $!
		
		# 启动服务
		run_service
		
		# 保持容器运行
		tail -f /dev/null
	fi
	
	if [ "$1" = "test" ]; then
		init_freeswitch_service "init"
	fi
fi