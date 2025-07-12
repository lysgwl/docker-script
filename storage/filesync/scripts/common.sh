#!/bin/bash
#

# 添加防重复加载检查
[[ -n "${_COMMON_SH_LOADED}" ]] && return 0
_COMMON_SH_LOADED=1

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 定时计划
readonly UPDATE_CHECK_SCHEDULE="0 3 * * 0"

# 初始标识
readonly RUN_FIRST_LOCK="/var/run/run_init_flag.pid"

# 更新标识
readonly RUN_UPDATE_LOCK="/var/run/run_update_flag.pid"

# 更新日志
readonly RUN_UPDATE_LOG="/var/log/run_update_log.log"

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
	["downloads_dir"]="${WORK_DIR}/downloads"		# 下载目录
	["install_dir"]="${WORK_DIR}/install"			# 安装目录
	["conf_dir"]="${WORK_DIR}/config"				# 预配置目录
	["config_dir"]="/config"						# 配置目录
	["data_dir"]="/data"							# 数据目录
	["usr_dir"]="/mnt/usr"							# 用户目录
	["arch"]="$(uname -m)"							# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"		# 系统类型
)

umask ${UMASK:-022}

readonly -A user_config
readonly -A sshd_config
readonly -A system_config

# 加载 feature 脚本
source $WORK_DIR/scripts/feature.sh

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载 openlist 脚本
source $WORK_DIR/scripts/set_openlist.sh

# 加载 syncthing 脚本
source $WORK_DIR/scripts/set_syncthing.sh

# 加载 filebrowser 脚本
source $WORK_DIR/scripts/set_filebrowser.sh

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

# 获取安装包
get_service_archive()
{
	local name="$1"
	local downloads_dir="$2"
	local download_callback="$3"
	
	local output_dir="$downloads_dir/output"
	mkdir -p "$output_dir" || return 1
	
	local findpath latest_path archive_path
	
	# 尝试查找现有归档文件
	if ! findpath=$(find_latest_archive "$downloads_dir" ".*${name}.*"); then
		echo "[WARNING] 未匹配到$name软件包..." >&2
		
		# 回调函数下载文件
		local download_file
		download_file=$(download_filebrowser "$downloads_dir") && [ -n "$download_file" ] || {
			echo "[ERROR] 下载$name软件包失败,请检查!" >&2
			return 2
		}
		
		# 提取并验证下载的文件
		archive_path=$(extract_and_validate "$download_file" "$output_dir" ".*${name}.*") || return 3
	else
		# 解析文件类型和路径
		local archive_type=$(jq -r '.filetype' <<< "$findpath")
		archive_path=$(jq -r '.filepath' <<< "$findpath")
		
		# 验证文件类型
		if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
			return 1
		fi
		
		if [ "$archive_type" = "file" ]; then
			archive_path=$(extract_and_validate "$archive_path" "$output_dir" ".*${name}.*") || return 3
		fi
	fi
	
	# 查找目标文件
	if [[ -f "$archive_path" ]]; then
		latest_path="$archive_path"
	else
		latest_path=$(find "$archive_path" -maxdepth 1 -mindepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)
		if [[ -z "$latest_path" ]] || [[ ! -f "$latest_path" ]]; then
			echo "[ERROR] $name可执行文件不存在,请检查!" >&2
			return 1
		fi
	fi
	
	echo "$latest_path"
}