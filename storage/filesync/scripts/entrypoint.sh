#!/bin/bash
#
set -eo pipefail

# 导出工作目录
export WORK_DIR="${WORK_DIR:-$(pwd)}"

# 加载 update 脚本
source $WORK_DIR/scripts/update.sh || exit 1

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
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
	
	if [[ "$1" = "run" ]]; then
		print_section "启动服务 ($1)"
		
		# 捕获 SIGTERM 信号
		#trap close_modules SIGTERM
		trap 'close_modules; exit 143' SIGTERM
		
		# 重新加载cron配置
		crond -l 2 -L /dev/stdout &

		# 执行业务模块
		exec_as_user ${USER_CONFIG[user]} "
			run_modules
		" &
		
		CHILD_PID=$!
		logger "INFO" "业务进程启动 (PID: $CHILD_PID)"
		
		# 等待业务进程退出
		wait $CHILD_PID
		
		local EXIT_CODE=$?
		logger "INFO" "业务进程退出, 退出码: $EXIT_CODE"
	fi
fi