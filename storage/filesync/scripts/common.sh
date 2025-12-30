#!/bin/bash
#

# 添加防重复加载检查
[[ "${_COMMON_SH_LOADED}" == "$$:${BASH_SOURCE[0]}" ]] && return 0
_COMMON_SH_LOADED="$$:${BASH_SOURCE[0]}"

export ENABLE_FILEBROWSER=false
export ENABLE_OPENLIST=true
export ENABLE_SYNCTHING=false
export ENABLE_VERYSYNC=false

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 定时计划(0 3 * * 0) (* * * * *)
readonly UPDATE_CHECK_SCHEDULE="0 3 * * 0"

# 初始标识
readonly RUN_FIRST_LOCK="/var/run/run_init_flag.pid"

# 更新标识
readonly RUN_UPDATE_LOCK="/var/run/run_update_flag.pid"

# utils模块目录
: ${UTILS_DIR:=${WORK_DIR:-/app}/utils}

# 定义用户配置数组
declare -A USER_CONFIG=(
	["uid"]="${PUID:-0}"
	["gid"]="${PGID:-0}"
	["user"]="${USERNAME:-root}"
	["group"]="${GROUPNAME:-root}"
)
readonly -A USER_CONFIG

# 定义 SSHD 配置数组
declare -A SSHD_CONFIG=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)
readonly -A SSHD_CONFIG

# 定义系统配置数组
declare -A SYSTEM_CONFIG=(
	["downloads_dir"]="${WORK_DIR}/downloads"		# 下载目录
	["install_dir"]="${WORK_DIR}/install"			# 安装目录
	["update_dir"]="/mnt/usr/downloads"				# 更新目录
	["conf_dir"]="${WORK_DIR}/config"				# 预配置目录
	["config_dir"]="/config"						# 配置目录
	["data_dir"]="/data"							# 数据目录
	["usr_dir"]="/mnt/usr"							# 用户目录
	["arch"]="$(uname -m)"							# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"		# 系统类型
	["update_log"]="/var/log/update.log"			# 更新日志
)
readonly -A SYSTEM_CONFIG

# 定义服务状态数组
declare -A SERVICE_ENABLED=(
	["filebrowser"]=${ENABLE_FILEBROWSER:-false}
	["openlist"]=${ENABLE_OPENLIST:-false}
	["syncthing"]=${ENABLE_SYNCTHING:-false}
	["verysync"]=${ENABLE_VERYSYNC:-false}
)
readonly -A SERVICE_ENABLED

umask ${UMASK:-022}

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

# ============================================================================
# 加载utils模块
auto_load_utils()
{
	# 检查是否已加载
	[[ -n "${UTILS_MODULE_LOADED:-}" ]] && [[ "${UTILS_MODULE_LOADED}" =~ ^utils_.*_${BASHPID:-$$}$ ]] && return 0
	
	# 检查 UTILS_DIR 目录
	if [[ ! -d "${UTILS_DIR}" ]]; then
		echo "[ERROR] utils目录不存在: ${UTILS_DIR}"
		return 1
	fi
	
	# 定义feature.sh路径
	local feature_file="${UTILS_DIR}/feature.sh"
	
	if [[ ! -f "${feature_file}" ]]; then
		echo "[ERROR] feature.sh文件不存在: ${feature_file}"
		return 1
	fi
	
	# 加载feature.sh
	echo "[INFO] 加载utils模块: ${feature_file}"
	source "${feature_file}"
	
	# 检查load_feature函数是否存在
	if ! declare -f load_feature >/dev/null; then
		echo "[ERROR] load_feature函数未定义!"
		return 1
	fi
	
	# 执行加载
	load_feature
	
	# 设置加载标记
	export UTILS_MODULE_LOADED="utils_$(date +%s)_${BASHPID:-$$}"
	return 0
}

# 检查服务是否启用
check_service_enabled()
{
	local service="$1"
	[[ "${SERVICE_ENABLED[$service]:-false}" == "true" ]]
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

# 执行命令作为指定用户
exec_as_user()
{
	local user="$1"
	shift
	
	local cmd="$*"
	
	# 验证用户存在
	if ! id "$user" &>/dev/null; then
		print_log "ERROR" "用户 '$user' 不存在!"
		return 1
	fi
	
	su-exec "$user" bash -c "
		#echo '[DEBUG] su-exec: ID($$)=' \$\$ >&2
		#echo '[DEBUG] su-exec: BASHPID=' \$BASHPID >&2
		#echo '[DEBUG] su-exec: ID(PPID)=' \$PPID >&2
		
		# 取消所有加载标记
		unset _COMMON_SH_LOADED UTILS_MODULE_LOADED 2>/dev/null || true
		
		# 重新加载 common.sh
		if ! source \"$WORK_DIR/scripts/common.sh\" 2>/dev/null; then
			echo '[ERROR] 加载脚本 common.sh 失败!' >&2
			exit 1
		fi
		
		# 执行命令
		$cmd
	"
	
	return $?
}

# 锁文件管理
lock_manager() 
{
	local action="$1"
	
	case "$action" in
		"check")
			if [ -f "$RUN_UPDATE_LOCK" ]; then
				print_log "WARNING" "更新已在进行中，跳过本次更新" "${SYSTEM_CONFIG[update_log]}"
				return 1
			fi
			
			return 0
			;;
		"create")
			touch "$RUN_UPDATE_LOCK" || {
				print_log "ERROR" "无法创建锁文件: $RUN_UPDATE_LOCK" "${SYSTEM_CONFIG[update_log]}"
				return 1
			}
			;;
		"remove")
			rm -f "$RUN_UPDATE_LOCK"
			;;
	esac
}

# 时间管理
time_manager() 
{
	local action="$1"
	local value="${2:-}"
	
	case "$action" in
		"start")
			echo $(date +%s)
			;;
		"calculate")
			local start_time=$value
			local end_time=$(date +%s)
			local duration=$((end_time - start_time))
			local minutes=$((duration / 60))
			local seconds=$((duration % 60))
			
			if [[ $minutes -gt 0 ]]; then
				echo "${minutes}分${seconds}秒"
			else
				echo "${duration}秒"
			fi
			;;
	esac
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
		print_log "WARNING" "未匹配到$name软件包..." >&2
		
		# 回调函数下载文件
		local download_file
		download_file=$($download_callback "$downloads_dir") && [ -n "$download_file" ] || {
			print_log "ERROR" "下载$name软件包失败,请检查!" >&2
			return 2
		}
		
		# 提取并验证下载的文件
		archive_path=$(extract_and_validate "$download_file" "$output_dir" ".*${name}.*") || {
			print_log "ERROR" "解压 $name 文件失败,请检查!" >&2
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
			print_log "ERROR" "解析 $name 文件失败,请检查!" >&2
			return 1
		fi
		
		if [ "$archive_type" = "file" ]; then
			archive_path=$(extract_and_validate "$archive_path" "$output_dir" ".*${name}.*") || {
				print_log "ERROR" "解压 $name 文件失败,请检查!" >&2
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
			print_log "ERROR" "可执行文件 $name 不存在,请检查!" >&2
			return 1
		fi
	fi
	
	echo "$latest_path"
}

# ============================================================================
# 初始化模块
init_modules()
{
	if [ "$(id -u)" -ne 0 ]; then
		print_log "ERROR" "非root用户权限无法初始环境, 请检查!"
		return 1
	fi
	
	local param=$1
	[ "$param" = "run" ] && param="config"
	
	# 初始服务环境
	if ! init_service "$param"; then
		return 1
	fi
	
	# 执行操作
	for service in "${!SERVICE_ENABLED[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi

		# 执行函数
		if ! execute_service_function "$service" "init" "$param"; then
			 print_log "ERROR" "初始化 $service 失败!"
			 return 1
		fi
	done
}

# 运行模块
run_modules()
{
	# 执行操作
	for service in "${!SERVICE_ENABLED[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi

		# 执行函数
		if ! execute_service_function "$service" "run"; then
			print_log "ERROR" "启动 $service 失败!"
		fi
	done
}

# 关闭模块
close_modules()
{
	# 执行操作
	for service in "${!SERVICE_ENABLED[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		# 执行函数
		if ! execute_service_function "$service" "close"; then
			print_log "ERROR" "关闭 $service 失败!"
		fi
	done
}

# 自动加载utils模块
auto_load_utils