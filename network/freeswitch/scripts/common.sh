#!/bin/bash
#

# 添加防重复加载检查
[[ "${_COMMON_SH_LOADED}" == "$$:${BASH_SOURCE[0]}" ]] && return 0
_COMMON_SH_LOADED="$$:${BASH_SOURCE[0]}"

# root 用户密码
readonly ROOT_PASSWORD="123456"

# 首次运行标识
readonly INIT_LOCK="/var/run/init.lock"

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
	["downloads_dir"]="$WORK_DIR/downloads"		# 下载目录
	["install_dir"]="$WORK_DIR/install"			# 安装目录
	["conf_dir"]="$WORK_DIR/config"				# 预配置目录
	["config_dir"]="/config"					# 配置目录
	["data_dir"]="/data"						# 数据目录
	["usr_dir"]="/mnt/usr"						# 用户目录
	["arch"]="$(uname -m)"						# 系统架构
	["type"]="$(uname | tr '[A-Z]' '[a-z]')"	# 系统类型
)
readonly -A SYSTEM_CONFIG

umask ${UMASK:-022}

# 加载服务脚本
source $WORK_DIR/scripts/set_service.sh

# 加载 freeswitch 脚本
source $WORK_DIR/scripts/set_freeswitch.sh

# ============================================================================
# 工具函数

# 获取服务源码
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
		print_log "WARNING" "未匹配到 $name 软件包..." >&2
		
		# 克隆Git仓库到下载目录
		archive_path=$(clone_repo "$json_config" "$downloads_dir") || {
			print_log "ERROR" "克隆 $name 源代码失败, 请检查!" >&2
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
			print_log "ERROR" "解析 $name 文件失败, 请检查!" >&2
			return 1
		fi
		
		# 解压源码文件
		if [ "$archive_type" = "file" ]; then
			archive_path=$(extract_and_validate "$archive_path" "$output_dir" "$name.*") || {
				print_log "ERROR" "解压 $name 源码文件失败, 请检查!" >&2
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
				rsync -a "$archive_path/" "$target_dir/"
			fi
		fi
		
		# 输出目录中的路径
		latest_path="$target_dir"
	fi
	
	# 返回源代码路径
	echo "$latest_path"
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
		print_log "ERROR" "用户 '$user' 不存在, 请检查!"
		return 1
	fi
	
	gosu "$user" bash -c "
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
	
	# 初始 freeswitch 环境
	if ! init_freeswitch_service "$param"; then
		print_log "ERROR" "初始化 freeswitch 失败!"
		return 1
	fi
	
	return 0
}

# 运行业务模块
run_modules()
{
	# 启动 freeswitch 服务
	run_freeswitch_service
}

# 关闭业务模块
close_modules()
{
	# 关闭 freeswitch 服务
	close_freeswitch_service
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