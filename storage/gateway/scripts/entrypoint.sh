#!/bin/bash

set -eo pipefail

# 导出工作目录
export WORK_DIR="${WORK_DIR:-$(pwd)}"

echo "========================================"
echo "网关服务启动"
echo "工作目录: $WORK_DIR"
echo "启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# 加载 common 脚本
source $WORK_DIR/scripts/common.sh

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	if [ "$1" = "test" ]; then
		init_mount
	else
		echo "--- 第一阶段：初始化服务 ---"
		
		if ! init_gateway; then
			echo "网关初始化失败, 请检查!"
			exit 1
		fi
		
		echo "--- 第二阶段：启动服务 ---"
		if ! run_gateway; then
			echo "网关启动失败, 请检查!"
			exit 1
		fi
		
		echo "========================================"
		echo "网关服务启动完成，正在运行..."
		echo "========================================"
		
		# 捕获 SIGTERM 信号
		trap close_gateway SIGTERM
		
		# 保持容器运行
		tail -f /dev/null
	fi
fi