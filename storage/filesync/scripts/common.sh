#!/bin/bash
#

# 添加防重复加载检查
[[ "${_COMMON_SH_LOADED}" == "$$:${BASH_SOURCE[0]}" ]] && return 0
_COMMON_SH_LOADED="$$:${BASH_SOURCE[0]}"

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 定时计划(0 3 * * 0) (* * * * *)
readonly UPDATE_CHECK_SCHEDULE="0 3 * * 0"

# 初始锁
readonly INIT_LOCK="/var/run/init.lock"

# 更新锁
readonly UPDATE_LOCK="/var/run/update.lock"

# 状态文件
readonly SERVICE_STATES_FILE="/var/run/service_states.json"

# 状态变量
: "${SERVICE_STATES_ENV:=_SERVICE_STATES_JSON}"

# utils模块目录
: ${UTILS_DIR:=${WORK_DIR:-/app}/utils}

# 用户配置
declare -A USER_CONFIG=(
	["uid"]="${PUID:-0}"
	["gid"]="${PGID:-0}"
	["user"]="${USERNAME:-root}"
	["group"]="${GROUPNAME:-root}"
)
readonly -A USER_CONFIG

# SSHD 配置
declare -A SSHD_CONFIG=(
	["port"]="${SSHD_PORT:-22}"
	["listen"]="0.0.0.0"
	["confile"]="/etc/ssh/sshd_config"
	["hostkey"]="/etc/ssh/ssh_host_rsa_key"
	["logfile"]="/var/log/sshd.log"
)
readonly -A SSHD_CONFIG

# 系统配置
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

umask ${UMASK:-022}

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载服务状态脚本
source $WORK_DIR/scripts/service_state.sh

# 加载 openlist 脚本
source $WORK_DIR/scripts/set_openlist.sh

# 加载 syncthing 脚本
source $WORK_DIR/scripts/set_syncthing.sh

# 加载 verysync 脚本
source $WORK_DIR/scripts/set_verysync.sh

# 加载 filebrowser 脚本
source $WORK_DIR/scripts/set_filebrowser.sh

# ============================================================================
# 工具函数

# 获取服务安装包
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
		print_log "WARNING" "未匹配到 $name 软件包..." >&2
		
		# 回调函数下载文件
		local download_file
		download_file=$($download_callback "$downloads_dir") && [ -n "$download_file" ] || {
			print_log "ERROR" "下载 $name 软件包失败, 请检查!" >&2
			return 2
		}
		
		# 提取并验证下载的文件
		archive_path=$(extract_and_validate "$download_file" "$output_dir" ".*${name}.*") || {
			print_log "ERROR" "解压 $name 文件失败, 请检查!" >&2
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
			print_log "ERROR" "解析 $name 文件失败, 请检查!" >&2
			return 1
		fi
		
		if [ "$archive_type" = "file" ]; then
			archive_path=$(extract_and_validate "$archive_path" "$output_dir" ".*${name}.*") || {
				print_log "ERROR" "解压 $name 文件失败, 请检查!" >&2
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
			print_log "ERROR" "可执行文件 $name 不存在, 请检查!" >&2
			return 1
		fi
	fi
	
	echo "$latest_path"
}

# 执行命令作为指定用户
exec_as_user()
{
	local user="$1"
	shift
	
	local cmd="$*"
	
	# 验证用户存在
	if ! id "$user" &>/dev/null; then
		print_log "ERROR" "用户 '$user' 不存在, 请检查!"
		return 1
	fi
	
	# 导出状态
	export_service_states
	
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
		
		# 加载服务状态
		load_service_states
		
		# 执行命令
		$cmd
	"
	
	return $?
}

# ============================================================================
# 模块周期函数

# 初始化业务模块
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
	for service in "${!SERVICE_STATES[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		# 更新状态 - 初始化
		update_service_status "$service" "${SERVICE_STATUS[INIT]}"

		# 执行函数
		if ! execute_service_func "$service" "init" "$param"; then
			update_service_status "$service" "${SERVICE_STATUS[FAILURE]}"
			
			print_log "ERROR" "初始化 $service 失败!"
			return 1
		fi
		
		update_service_status "$service" "${SERVICE_STATUS[SUCCESS]}"
	done
}

# 运行业务模块
run_modules()
{
	# 执行操作
	for service in "${!SERVICE_STATES[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		# 更新状态
		update_service_status "$service" "${SERVICE_STATUS[EXECUTING]}"

		# 执行函数
		if ! execute_service_func "$service" "run"; then
			print_log "ERROR" "启动 $service 失败!"
			update_service_status "$service" "${SERVICE_STATUS[FAILURE]}"
		else
			update_service_status "$service" "${SERVICE_STATUS[RUNNING]}"
		fi
	done
}

# 关闭业务模块
close_modules()
{
	# 执行操作
	for service in "${!SERVICE_STATES[@]}"; do
		if ! check_service_enabled "$service"; then
			continue
		fi
		
		# 检查是否在运行
		[[ $(get_service_status "$service") != "${SERVICE_STATUS[RUNNING]}" ]] && continue
		
		# 更新状态
		update_service_status "$service" "${SERVICE_STATUS[EXECUTING]}"
		
		# 执行函数
		if execute_service_func "$service" "close"; then
			update_service_status "$service" "${SERVICE_STATUS[STOPPED]}"
		else
			update_service_status "$service" "${SERVICE_STATUS[FAILURE]}"
			print_log "ERROR" "关闭 $service 失败!"
		fi
	done
}

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
		return 2
	fi
	
	# 加载feature.sh
	echo "[INFO] 加载utils模块: ${feature_file}"
	if ! source "${feature_file}"; then
		echo "[ERROR] 加载feature.sh失败: ${feature_file}" >&2
		return 3
	fi
	
	# 检查load_feature函数是否存在
	if ! declare -f load_feature >/dev/null; then
		echo "[ERROR] load_feature函数未定义!"
		return 4
	fi
	
	# 执行加载
	load_feature
	
	# 设置加载标记
	export UTILS_MODULE_LOADED="utils_$(date +%s)_${BASHPID:-$$}"
}

# 自动加载utils模块
auto_load_utils || return 1