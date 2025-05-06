#!/bin/bash

set -eo pipefail

# 工作目录
readonly WORK_DIR=$(pwd)

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

# 加载feature脚本
source $WORK_DIR/scripts/feature.sh

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载alist脚本
source $WORK_DIR/scripts/set_alist.sh

# 加载syncthing脚本
source $WORK_DIR/scripts/set_syncthing.sh

# 初始化模块
init_modules()
{
	local param=$1
	echo "[INFO] 当前用户:$(id -un), UID:$(id -u)"
	
	if [ "$(id -u)" -ne 0 ]; then
		echo "[ERROR] 非root用户权限无法初始环境, 请检查!"
		return 1
	fi
	
	# 初始服务环境
	if ! init_service_env "$param"; then
		return 1
	fi
	
	# 初始alist环境
	if ! init_alist_env "$param"; then
		return 1
	fi
	
	# 初始syncthing环境
	if ! init_syncthing_env "$param"; then
		return 1
	fi
	
	return 0
}

# 运行模块
run_modules()
{
	echo "[INFO] 当前用户:$(id -un), UID:$(id -u)"
	
	# alist服务
	run_alist_service

	# syncthing服务
	run_syncthing_service
}

# 关闭模块
close_modules()
{
	# alist服务
	close_alist_service
	
	# syncthing服务
	close_syncthing_service
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# 根据参数执行操作
	case "$1" in
		init)
			# 初始化配置
			if ! init_modules "init"; then
				exit 1
			fi
			
			# while true; do echo 'Running...'; sleep 60; done
			;;
		run)
			# 捕获 SIGTERM 信号
			trap close_modules SIGTERM
			
			# 运行阶段初始化
			if [ ! -f "${RUN_FIRST_LOCK}" ]; then
				if ! init_modules "config"; then
					exit 1
				fi
	
				touch "${RUN_FIRST_LOCK}"
			fi
			
			# 以 APP_USER 用户权限执行 run_modules
			su-exec ${user_config[user]}:${user_config[group]} bash -c "
				source /app/scripts/entrypoint.sh
				run_modules
			" &

			# 等待 run_modules 执行完成
			wait $!
			
			# 启动服务
			# run_service
			
			# 保持容器运行
			tail -f /dev/null
			;;
	esac
fi