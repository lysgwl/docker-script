#!/bin/bash

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

# 加载 nginx 脚本
source $WORK_DIR/scripts/set_nginx.sh

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
	
	# nginx 服务
	if ! init_nginx_service "$param"; then
		return 1
	fi
	
	return 0
}

# 运行模块
run_modules()
{
	echo "[WARNING] running 当前用户:$(id -un), UID:$(id -u), UMASK:$(umask)"
	
	# 启动 nginx 服务
	run_nginx_service
}

# 关闭模块
close_modules()
{
	# 关闭 nginx 服务
	close_nginx_service
}

# 获取源码
get_service_sources()
{
	local name="$1"
	local downloads_dir="$2"
	local json_config="$3"
	
	# 创建输出目录，存放解压后的源代码
	local output_dir="$downloads_dir/output"
	mkdir -p "$output_dir" || return 1
	
	# 声明局部变量
	local findpath latest_path archive_path archive_name archive_type
	
	# 在下载目录, 查找现有归档文件
	if ! findpath=$(find_latest_archive "$downloads_dir" ".*${name}.*"); then
		echo "[WARNING] 未匹配到$name软件包..." >&2
		
		# 克隆Git仓库到下载目录
		archive_path=$(clone_repo "$json_config" "$downloads_dir") || {
			echo "[ERROR] 克隆 $name 源代码失败,请检查!" >&2
			return 2
		}
		
		# 获取归档名称和类型
		archive_type="directory"
		archive_name=$(basename "$archive_path")
	else
		# 解析文件类型和路径
		archive_type=$(jq -r '.filetype' <<< "$findpath")
		archive_path=$(jq -r '.filepath' <<< "$findpath")
		archive_name=$(jq -r '.name' <<< "$findpath")
		
		# 验证文件类型
		if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
			echo "[ERROR] 解析 $name 文件失败,请检查!" >&2
			return 1
		fi
		
		# 解压源码文件
		if [ "$archive_type" = "file" ]; then
			archive_path=$(extract_and_validate "$archive_path" "$output_dir" "$name.*") || {
				echo "[ERROR] 解压 $name 源码文件失败,请检查!" >&2
				return 3
			}
			
			archive_name=$(basename "$archive_path")
		fi
	fi
	
	# 确定源代码路径
	if [[ -f "$archive_path" ]]; then
		latest_path="$archive_path"
	else
		# 如果是目录类型, 同步到输出目录
		local target_dir="$output_dir/$archive_name"
		
		if [ "$archive_type" = "directory" ]; then
			# 同步内容至输出目录
			if [ ! -e "$target_dir" ]; then
				rsync -a --exclude '.*' "$archive_path/" "$target_dir/"
			fi
		fi
		
		# 输出目录中的路径
		latest_path="$target_dir"
	fi
	
	# 返回源代码路径
	echo "$latest_path"
	return 0
}