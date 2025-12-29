#!/bin/bash
# 系统工具模块

if [[ -n "${SYSTEM_UTILS_LOADED:-}" ]]; then
	return 0
fi
export SYSTEM_UTILS_LOADED=1

# 安装运行文件
install_binary()
{
	local src_path=$1
	local dest_path=$2
	local symlink_path=${3:-}
	
	# 处理通配符
	local has_wildcard=0
	[[ "$src_path" == *[\*\?\[]* ]] && has_wildcard=1
	
	local sources=()
	if [[ $has_wildcard -eq 1 ]]; then
		for file in $src_path; do
			[[ -e "$file" ]] && sources+=("$file")
		done
		
		# 检查是否匹配到任何文件
		if [[ ${#sources[@]} -eq 0 ]]; then
			echo "[ERROR] 通配符未匹配到任何文件: $src_path" >&2
			return 1
		fi
	else
		# 校验源路径类型
		if [[ ! -e "$src_path" ]]; then
			echo "[ERROR] 源文件$src_path不存在,请检查!" >&2
			return 1
		fi
		
		sources=("$src_path")
	fi
	
	if [[ -z "$dest_path" ]]; then
		# 创建符号链接
		if [[ -n "$symlink_path" ]]; then
			ln -sfn "${sources[0]}" "$symlink_path" 2>/dev/null || {
				echo "[ERROR] 创建符号链接失败: $symlink_path" >&2
				return 4
			}
		fi
	else
		mkdir -p "$dest_path" || {
			echo "[ERROR] 无法创建目录 $dest_path !" >&2
			return 2
		}
		
		# 复制文件/目录
		for source in "${sources[@]}"; do
			local target_name=$(basename "$source")
			local target_path="$dest_path/$target_name"
			
			# 删除已存在的目标
			rm -rf "$target_path"
			
			# 复制源到目标
			if [[ -d "$source" ]]; then
				# 复制整个目录
				cp -a "$source" "$dest_path/" || {
					echo "[ERROR] 目录复制失败: $source" >&2
					return 3
				}
			else
				# 复制单个文件
				cp -a "$source" "$target_path" || {
					 echo "[ERROR] 文件复制失败: $source" >&2
					 return 3
				}
				
				# 设置可执行权限
				chmod +x "$target_path"
			fi
		done
		
		# 创建符号链接
		if [[ -n "$symlink_path" ]]; then
			local symlink_target="$dest_path"
			if [[ ${#sources[@]} -eq 1 && ! -d "${sources[0]}" ]]; then
				symlink_target="$dest_path/$(basename "${sources[0]}")"
			fi
			
			ln -sfn "$symlink_target" "$symlink_path" 2>/dev/null || {
				echo "[ERROR] 创建符号链接失败: $symlink_path" >&2
				return 4
			}
		fi
	fi
	
	return 0
}

# 增加服务用户
add_service_user()
{
	local user="$1"
	local group="$2"
	local uid="$3"
	local gid="$4"
	
	local addgroup_cmd adduser_cmd
	
	if [ -f /etc/alpine-release ]; then
		addgroup_cmd="addgroup -g $gid $group"
		adduser_cmd="adduser -D -H -G $group -u $uid $user"
	else
		addgroup_cmd="groupadd --gid $gid $group"
		adduser_cmd="useradd --create-home --shell /bin/bash --gid $group --uid $uid $user"
	fi
	
	# 创建组
	if ! getent group $group >/dev/null; then
		$addgroup_cmd || {
			echo "[ERROR] 无法创建组${group}, 请检查!"
			return 1
		}
		
		echo "[DEBUG] 成功创建组${group}"
	fi
	
	# 创建用户
	if ! id -u $user >/dev/null 2>&1; then
		$adduser_cmd || {
			echo "[ERROR] 无法创建用户$user, 请检查!"
			return 1
		}
		
		echo "[DEBUG] 成功创建用户$user"
	fi
	
	return 0
}

# 设置SSH服务
set_ssh_service()
{
	local sshd_port="$1"
	local sshd_listen_address="$2"
	local sshd_file="$3"
	local sshd_rsakey="$4"
	
	# 验证配置文件存在
	if [ ! -f "$sshd_file" ]; then
		echo "[ERROR] SSH服务没有安装,请检查!"
		return 1
	fi
	
	# 备份配置
	cp -f "$sshd_file" "$sshd_file.bak"
	
	# 设置ssh端口号
	if [ -n "$sshd_port" ]; then
		local ssh_port=$(grep -E '^(#?)Port [[:digit:]]*$' "$sshd_file")
		if [ -n "$ssh_port" ]; then
			sed -E -i "s/^(#?)Port [[:digit:]]*$/Port $sshd_port/" "$sshd_file"
		else
			echo -e "Port $sshd_port" >> "$sshd_file"
		fi
	else
		sed -i -E '/^Port[[:space:]]+[0-9]+/s/^/#/' "$sshd_file"
	fi
	
	# 设置监听IP地址
	if [ -n "$sshd_listen_address" ]; then
		# grep -Po '^.*ListenAddress\s+([^\s]+)' "${sshd_file}" | grep -Po '([0-9]{1,3}\.){3}[0-9]{1,3}'
		# grep -Eo '^.*ListenAddress[[:space:]]+([^[:space:]]+)' ${sshd_file} | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'
		local ipv4_address=$(awk '/ListenAddress[[:space:]]+/ {print $2}' $sshd_file | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
		if [ -n "$ipv4_address" ]; then
			sed -i -E 's/^(\s*)#?(ListenAddress)\s+([0-9]{1,3}\.){3}[0-9]{1,3}/\1\2 '"$sshd_listen_address"'/' "$sshd_file"
		else
			echo "ListenAddress $sshd_listen_address" >> "$sshd_file"
		fi
	else
		sed -i -E '/^ListenAddress\s+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/s/^/#/' "$sshd_file"
	fi
	
	# 设置ssh密钥KEY
	if [ ! -f "$sshd_rsakey" ]; then
		ssh-keygen -t rsa -N "" -f "$sshd_rsakey"
	fi
	
	# 注释密钥ssh_host_ecdsa_key
	if [ -z "`sed -n '/^#.*HostKey .*ecdsa_key/p' $sshd_file`" ]; then
		sed -i '/^HostKey .*ecdsa_key$/s/^/#/' "$sshd_file"
	fi
	
	# 注释密钥ssh_host_ed25519_key
	if [ -z "`sed -n '/^#.*HostKey .*ed25519_key/p' $sshd_file`" ]; then
		sed -i '/^HostKey .*ed25519_key$/s/^/#/' "$sshd_file"
	fi
	
	# 设置PermitRootLogin管理员权限登录
	if grep -q -E "^#?PermitRootLogin" "$sshd_file"; then
		sed -i -E 's/^(#?PermitRootLogin).*/PermitRootLogin yes/' "$sshd_file"
	else
		echo "PermitRootLogin yes" >> "$sshd_file"
	fi
	
	# 设置PasswordAuthentication密码身份验证
	if grep -q -E "^#?PasswordAuthentication" "$sshd_file"; then
		sed -i -E 's/^(#?PasswordAuthentication).*/PasswordAuthentication yes/' "$sshd_file"
	else
		echo "PasswordAuthentication yes" >> "$sshd_file"
	fi
	
	# 设置SSHD进程pid文件路径
	if [ -z "$(awk '/#PidFile /{getline a; print a}' "$sshd_file" | sed -n '/^PidFile \/var\/run\/sshd.pid/p')" ]; then
		sed -i '/^#PidFile / a\PidFile \/var\/run\/sshd.pid' "$sshd_file"
	fi
	
	local ssh_dir="/root/.ssh"
	if [ ! -d "$ssh_dir" ]; then
		mkdir -p "$ssh_dir"
	fi
	
	chmod 700 "$ssh_dir"
	return 0
}

# 等待进程 id
wait_for_pid()
{
	local timeout=${1:-10}
	local pid_source=${2:-}
	local process_name=${3:-}
		
	local max_attempts=$timeout
	local process_pid=""
	local elapsed=0
	
	local result=0
	local last_status="启动中..."
	
	if [[ -z "$pid_source" && -z "$process_name" ]]; then
		echo -e "\033[31m❌ [ERROR] 未提供 PID 源或进程名\033[0m"
		return 1
	fi
	
	# 显示开始信息
	echo -e "\033[34m⏳ 等待进程启动 | 超时: ${timeout}秒\033[0m"
	
	while ((elapsed <= max_attempts)); do
		local remaining=$((max_attempts - elapsed))
		echo -e "\033[33m🕒 已等待: ${elapsed}秒 | 剩余: ${remaining}秒 | 状态: ${last_status}\033[0m"
		
		if [[ -n "$pid_source" ]]; then
			if [[ -f "$pid_source" ]]; then
				process_pid=$(tr -d '[:space:]' < "$pid_source" 2>/dev/null)
			elif [[ "$pid_source" =~ ^[0-9]+$ ]]; then
				process_pid="$pid_source"
			fi
		elif [[ -n "$process_name" ]]; then
			process_pid=$(pgrep -f "$process_name" | head -n1)
		fi
		
		# 验证 PID
		if [[ -z "$process_pid" ]]; then
			result=2
			last_status="未获取到 PID"
		elif ! [[ "$process_pid" =~ ^[0-9]+$ ]]; then
			result=3
			last_status="PID无效: $process_pid"
		elif ! kill -0 "$process_pid" >/dev/null 2>&1; then
			result=4
			last_status="PID不存在: $process_pid"
		elif [[ -n "$process_name" ]]; then
			local actual_name=$(ps -p "$process_pid" -o comm= 2>/dev/null)
			if [[ ! "$actual_name" =~ $process_name ]]; then
				result=5
				last_status="进程不匹配: '$process_name'≠'$actual_name'"
			else
				result=0
				break
			fi
		else
			result=0
			break
		fi
		
		sleep 1
		((elapsed++))
	done
	
	if ((elapsed >= timeout)); then
		result=6
		last_status="运行超时"
	fi
	
	if ((result == 0)); then
		echo -e "\033[32m✅ 进程启动成功! PID: $process_pid | 耗时: ${elapsed}秒\033[0m"
	else
		echo -e "\033[31m❌ 进程启动失败! | 超时: ${timeout}秒 | 最后状态: ${last_status}\033[0m"
	fi
	
	return $result
}