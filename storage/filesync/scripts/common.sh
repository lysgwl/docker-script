#!/bin/bash
#

# 添加防重复加载检查
[[ -n "${_COMMON_SH_LOADED}" ]] && return 0
_COMMON_SH_LOADED=1

export ENABLE_FILEBROWSER=false
export ENABLE_OPENLIST=true
export ENABLE_SYNCTHING=true
export ENABLE_VERYSYNC=true

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 定时计划(0 3 * * 0) (* * * * *)
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
readonly -A user_config

# 定义 SSHD 配置数组
declare -A sshd_config=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)
readonly -A sshd_config

# 定义系统配置数组
declare -A system_config=(
	["downloads_dir"]="${WORK_DIR}/downloads"		# 下载目录
	["install_dir"]="${WORK_DIR}/install"			# 安装目录
	["update_dir"]="/mnt/usr/downloads"				# 更新目录
	["conf_dir"]="${WORK_DIR}/config"				# 预配置目录
	["config_dir"]="/config"						# 配置目录
	["data_dir"]="/data"							# 数据目录
	["usr_dir"]="/mnt/usr"							# 用户目录
	["arch"]="$(uname -m)"							# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"		# 系统类型
)
readonly -A system_config

# 定义服务状态数组
declare -A service_enabled=(
	["filebrowser"]=${ENABLE_FILEBROWSER:-false}
	["openlist"]=${ENABLE_OPENLIST:-false}
	["syncthing"]=${ENABLE_SYNCTHING:-false}
	["verysync"]=${ENABLE_VERYSYNC:-false}
)
readonly -A service_enabled

umask ${UMASK:-022}

# 加载 feature 脚本
source $WORK_DIR/scripts/feature.sh

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载 openlist 脚本
source $WORK_DIR/scripts/set_openlist.sh

# 加载 syncthing 脚本
source $WORK_DIR/scripts/set_syncthing.sh

# 加载 verysync 脚本
source $WORK_DIR/scripts/set_verysync.sh

# 加载 filebrowser 脚本
source $WORK_DIR/scripts/set_filebrowser.sh

# 检查服务是否启用
check_service_enabled()
{
	local service="$1"
	[[ "${service_enabled[$service]:-false}" == "true" ]]
}

# 动态构建执行函数
execute_service_function()
{
	local service="$1"
	local operation="$2"
	local param="${3:-}"
	
	if check_service_enabled "$service"; then
		# 动态构建函数名
		local function_name="${operation}_${service}_service"
		
		if type -t "$function_name" &>/dev/null; then
			if [[ -n "$param" ]]; then
				$function_name "$param"
			else
				$function_name
			fi
			
			return $?
		fi
	fi
	
	return 0
}

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
	
	# 执行操作
	for service in "${!service_enabled[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		echo "[INFO] 初始化服务: $service"
		
		# 执行函数
		if ! execute_service_function "$service" "init" "$param"; then
			 echo "[ERROR] $service 初始化失败!"
			 return 1
		fi
	done
}

# 运行模块
run_modules()
{
	echo "[WARNING] running 当前用户:$(id -un), UID:$(id -u), UMASK:$(umask)"
	
	# 执行操作
	for service in "${!service_enabled[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		echo "[INFO] 启动服务: $service"
		
		# 执行函数
		if ! execute_service_function "$service" "run"; then
			echo "[ERROR] $service 启动失败!"
		fi
	done
}

# 关闭模块
close_modules()
{
	# 执行操作
	for service in "${!service_enabled[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		echo "[INFO] 关闭服务: $service"
		
		# 执行函数
		if ! execute_service_function "$service" "close"; then
			echo "[ERROR] $service 关闭失败!"
		fi
	done
}

# 获取安装包
get_service_archive()
{
	local name="$1"
	local downloads_dir="$2"
	local download_callback="$3"		# 下载回调函数
	local exclude_patterns=("${@:4}") 	# 排除模式数组
	
	local output_dir="$downloads_dir/output"
	mkdir -p "$output_dir" || return 1
	
	local findpath latest_path archive_path archive_type
	
	# 尝试查找现有归档文件
	if ! findpath=$(find_latest_archive "$downloads_dir" ".*${name}.*"); then
		echo "[WARNING] 未匹配到$name软件包..." >&2
		
		# 回调函数下载文件
		local download_file
		download_file=$($download_callback "$downloads_dir") && [ -n "$download_file" ] || {
			echo "[ERROR] 下载$name软件包失败,请检查!" >&2
			return 2
		}
		
		# 提取并验证下载的文件
		archive_path=$(extract_and_validate "$download_file" "$output_dir" ".*${name}.*") || {
			echo "[ERROR] 解压 $name 文件失败,请检查!" >&2
			return 3
		}
		
		# 获取归档名称和类型
		archive_type="file"
	else
		# 解析文件类型和路径
		archive_type=$(jq -r '.filetype' <<< "$findpath")
		archive_path=$(jq -r '.filepath' <<< "$findpath")
		
		# 验证文件类型
		if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
			echo "[ERROR] 解析 $name 文件失败,请检查!" >&2
			return 1
		fi
		
		if [ "$archive_type" = "file" ]; then
			archive_path=$(extract_and_validate "$archive_path" "$output_dir" ".*${name}.*") || {
				echo "[ERROR] 解压 $name 文件失败,请检查!" >&2
				return 3
			}
		fi
	fi
	
	# 查找目标文件
	if [[ -f "$archive_path" ]]; then
		latest_path="$archive_path"
	else
		if [ ${#exclude_patterns[@]} -gt 0 ]; then
			# 构建排除条件
			local exclude_conditions=()
			for pattern in "${exclude_patterns[@]}"; do
				exclude_conditions+=(-name "$pattern" -o)
			done
			
			# 移除最后多余的"-o"
			unset 'exclude_conditions[${#exclude_conditions[@]}-1]'
			
			latest_path=$(find "$archive_path" -maxdepth 1 -mindepth 1 -type f \
				-name "${name}*" -not \( "${exclude_conditions[@]}" \) \
				-print -quit 2>/dev/null)
		else
			latest_path=$(find "$archive_path" -maxdepth 1 -mindepth 1 -type f -name "${name}*" -print -quit 2>/dev/null)
		fi
		
		if [[ -z "$latest_path" ]] || [[ ! -f "$latest_path" ]]; then
			echo "[ERROR] $name可执行文件不存在,请检查!" >&2
			return 1
		fi
	fi
	
	echo "$latest_path"
}