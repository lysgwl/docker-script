#!/bin/bash
set -eo pipefail

# 导出工作目录
export WORK_DIR="${WORK_DIR:-$(pwd)}"

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh

# 加载 update 脚本
source $WORK_DIR/scripts/update.sh

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
			source \"$WORK_DIR/scripts/common.sh\"
			run_modules
		" &
		
		wait $!
		
		# 保持容器运行
		tail -f /dev/null
	fi
fi