#!/bin/bash
#

# 添加防重复加载检查
[[ -n "${_COMMON_SH_LOADED}" ]] && return 0
_COMMON_SH_LOADED=1

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 首次运行标识
readonly RUN_FIRST_LOCK="/var/run/first_run_flag.pid"

# 定义用户配置数组
declare -A user_config=(
	["uid"]="${PUID:-0}"
	["gid"]="${PGID:-0}"
	["user"]="${USERNAME:-root}"
	["group"]="${GROUPNAME:-root}"
)

# 定义 SSHD 配置数组
declare -A sshd_config=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)

# 定义系统配置数组
declare -A system_config=(
	["downloads_dir"]="$WORK_DIR/downloads"		# 下载目录
	["install_dir"]="$WORK_DIR/install"			# 安装目录
	["conf_dir"]="$WORK_DIR/config"				# 预配置目录
	["config_dir"]="/config"					# 配置目录
	["data_dir"]="/data"						# 数据目录
)

umask ${UMASK:-022}

readonly -A user_config
readonly -A sshd_config
readonly -A system_config

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
		echo "[ERROR] 非root用户权限无法初始环境, 请检查!" >&2
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


