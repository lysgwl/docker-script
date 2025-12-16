#!/bin/bash
#

# 添加防重复加载检查
[[ -n "${_COMMON_SH_LOADED}" ]] && return 0
_COMMON_SH_LOADED=1

# 定义系统配置数组
declare -A system_config=(
	["downloads_dir"]="${WORK_DIR}/downloads"		# 下载目录
	["install_dir"]="${WORK_DIR}/install"			# 安装目录
	["conf_dir"]="${WORK_DIR}/config"				# 预配置目录
	["config_dir"]="/config"						# 配置目录
	["data_dir"]="/data"							# 数据目录
	["arch"]="$(uname -m)"							# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"		# 系统类型
)
readonly -A system_config

umask ${UMASK:-022}

# 加载 feature 脚本
source $WORK_DIR/scripts/feature.sh

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载挂载脚本
source $WORK_DIR/scripts/set_mount.sh

# 初始化网关
init_gateway()
{
	echo "=== 初始化挂载服务 ==="
	
	# 显示配置信息
	print_log "INFO" "工作目录: $WORK_DIR"
	print_log "INFO" "系统架构: ${system_config[arch]}"
	print_log "INFO" "系统类型: ${system_config[type]}"
	print_log "INFO" "配置目录: ${system_config[config_dir]}"
	
	# 初始化服务
	echo "=== 步骤 1/2: 初始化系统服务 ==="
	if ! init_service; then
		print_log "ERROR" "系统服务初始化失败, 请检查!"
		return 1
	fi
	
	# 初始化挂载系
	echo "=== 步骤 2/2: 初始化挂载系统 ==="
	if ! init_mount; then
		print_log "ERROR" "挂载系统初始化失败, 请检查!"
		return 1
	fi
	
	print_log "INFO" "完成初始化检查"
	return 0
}

# 运行网关
run_gateway()
{
	echo "=== 启动挂载服务 ==="
	
	if ! run_mount "start" "--daemon"; then
		print_log "ERROR" "挂载服务启动失败, 请检查!"
		return 1
	fi
	
	print_log "INFO" "挂载服务运行中..."
	return 0
}

# 关闭网关
close_gateway()
{
	echo "=== 关闭挂载服务 ==="
	
	if ! close_mount "stop"; then
		print_log "WARN" "挂载服务停止时遇到问题, 请检查!"
		reutrn 1
	fi
	
	print_log "INFO" "关闭挂载服务"
	return 0
}
