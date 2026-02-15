#!/bin/bash

set -eo pipefail

# 导出工作目录
export WORK_DIR="${WORK_DIR:-$(pwd)}"

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh || exit 1

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	
	# 加载服务状态
	print_section "加载服务状态"
	load_service_states "${USER_CONFIG[user]}" "${USER_CONFIG[group]}"

	# 检查初始锁
	if lock_manager "check" "$INIT_LOCK"; then
		print_section "初始化 ($1)"
		
		# 初始化业务模块
		if ! init_modules "$1"; then
			exit 1
		fi
		
		# 创建初始锁
		lock_manager "create" "$INIT_LOCK"
	fi
	
	#install_service_env "init"
	
	if [[ "$1" = "run" ]]; then
		print_section "启动服务 ($1)"
		
		# 处理信号
		setup_signal_handler "close_modules"
		
		# 执行业务模块
		run_modules
		
		EXIT_CODE=$?
		logger "INFO" "业务进程退出, 返回码: $EXIT_CODE"
	fi
	
	if [[ "$1" = "test" ]]; then
		init_modules "init"
	fi
fi