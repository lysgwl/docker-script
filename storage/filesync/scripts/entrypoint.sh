#!/bin/bash
#
set -eo pipefail

# 导出工作目录
export WORK_DIR="${WORK_DIR:-$(pwd)}"

# 加载 update 脚本
source $WORK_DIR/scripts/update.sh || exit 1

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	if [[ ! -f "${RUN_FIRST_LOCK}" ]]; then
		print_section "初始化 ($1)"
		
		if ! init_modules "$1"; then
			exit 1
		fi
		
		# 设置定时更新任务
		schedule_updates
		
		touch "${RUN_FIRST_LOCK}"
	fi
	
	if [ "$1" = "run" ]; then
		print_section "启动服务 ($1)"

		# 捕获 SIGTERM 信号
		trap close_modules SIGTERM
		
		# 重新加载cron配置
		crond -l 2 -L /dev/stdout &

		# 执行模块
		exec_as_user ${USER_CONFIG[user]} "
			run_modules
		" &
		
		wait $!
		
		# 保持容器运行
		tail -f /dev/null
	fi
fi