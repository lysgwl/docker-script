#!/bin/bash

# freeswitch 配置数组
declare -A freeswitch_config=(
	["name"]="freeswitch"
	["passwd"]="123456"
	["sys_path"]="/usr/local/freeswitch"
	["etc_path"]="${system_config[config_dir]}"
	["data_path"]="${system_config[data_dir]}"
	["bin_path"]="/usr/local/freeswitch/bin"
	["lib_path"]="${system_config[data_dir]}/lib/freeswitch"
	["log_path"]="${system_config[data_dir]}/log/freeswitch"
	["run_path"]="${system_config[data_dir]}/run/freeswitch"
	["external_ip"]="$(echo "${EXTERNAL_IP:-}" | tr -d '"')"
)

# freeswitch 源码数组
declare -A freeswitch_sources=(
	["libks"]='{"repo":"signalwire/libks", "version":"latest"}'
	["sofia-sip"]='{"repo":"freeswitch/sofia-sip", "version":"latest"}'
	["spandsp"]='{"repo":"freeswitch/spandsp", "version":"0d2e6ac65e0e8f53d652665a743015a88bf048d4"}'
	["signalwire-c"]='{"repo":"signalwire/signalwire-c", "version":"latest"}'
	["freeswitch"]='{"repo":"signalwire/freeswitch", "version":"latest"}'
)

readonly -A freeswitch_config

# 获取 freeswitch 源码
fetch_freeswitch_source()
{
	local downloads_dir=$1
	echo "[INFO] 获取${freeswitch_config[name]}源码" >&2

	for key in "${!freeswitch_sources[@]}"; do
		local name="$key"
		local source_config="${freeswitch_sources[$name]}"
		
		if [[ -z "$source_config" ]]; then
			continue
		fi
		
		# 解析 JSON 配置
		local repo=$(jq -r '.repo' <<< "$source_config")
		local version=$(jq -r '.version' <<< "$source_config")
		
		# 如果repo为空，跳过该源码获取
		if [[ -z "$repo" ]]; then
			echo "[INFO] 跳过 $name 源码获取,未配置仓库" >&2
			continue
		fi
		
		local url="https://github.com/$repo.git"
		echo "[INFO] 正在获取$name源码..." >&2
		
		# 构建克隆仓库的配置
		local json_config=$(jq -n \
				--arg type "github" \
				--arg name "$name" \
				--arg repo "$repo" \
				--arg version "$version" \
				--arg url "${url}" \
				'{
					type: $type,
					name: $name,
					repo: $repo,
					version:$version,
					url: $url
				}')
				
		# 获取源码路径
		local source_path
		source_path=$(get_service_sources "$name" "$downloads_dir" "$json_config")
		
		local ret=$?
		if [ $ret -ne 0 ]; then
			echo "[ERROR] 获取 $name 源码失败，错误码: $ret" >&2
			break
		fi
	
		freeswitch_sources[$key]=$(jq --arg path "$source_path" '. + {path: $path}' <<< "$source_config")
	done 
	
	return $ret
}

# 编译 libks 源码
build_libks_source()
{
	# 获取 libks 源码路径
	local path=$(jq -r '.path // empty' <<< "${freeswitch_sources[libks]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		echo "[ERROR] 获取 libks 源码路径失败! ($path)"
		return 1
	fi
	
	cd "$path"
	
	# 配置 CMake	-DWITH_LIBBACKTRACE=1
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=$(dirname "${freeswitch_config[sys_path]}") -DCMAKE_BUILD_TYPE=Release || {
		echo "[ERROR] libks源码CMake配置失败,请检查!"
		return 2
	}
	
	# 编译 libks
	make -j$(nproc) || {
		echo "[ERROR] libks源码编译失败,请检查!"
		return 3
	}
	
	# 安装 libks
	make install || {
		echo "[ERROR] libks安装失败,请检查!"
		return 4
	}
	
	# 清理源码
	rm -rf "$path"
	return 0
}

# 编译 sofia-sip 源码
build_sofia-sip_source()
{
	# 获取 sofia-sip 源码路径
	local path=$(jq -r '.path // empty' <<< "${freeswitch_sources[sofia-sip]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		echo "[ERROR] 获取 sofia-sip 源码路径失败! ($path)"
		return 1
	fi
	
	cd "$path"
	
	# 配置 configure 源码编译环境
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" \
		--with-pic \
		--with-glib=no \
		--without-doxygen \
		--disable-stun \
		--prefix="$(dirname "${freeswitch_config[sys_path]}")"
	
	# 编译 sofia-sip
	make -j$(nproc) || {
		echo "[ERROR] sofia-sip源码编译失败,请检查!"
		return 3
	}
	
	# 安装 sofia-sip
	make install || {
		echo "[ERROR] sofia-sip安装失败,请检查!"
		return 4
	}
	
	# 清理源码
	rm -rf "$path"
	return 0
}

# 编译 spandsp 源码
build_spandsp_source()
{
	# 获取 spandsp 源码路径
	local path=$(jq -r '.path // empty' <<< "${freeswitch_sources[spandsp]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		echo "[ERROR] 获取 spandsp 源码路径失败! ($path)"
		return 1
	fi
	
	# git clone https://github.com/freeswitch/spandsp.git
	# git checkout -b compatible_version 0d2e6ac65e0e8f53d652665a743015a88bf048d4
	
	cd "$path"
	
	# 配置 configure 源码编译环境
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" \
		--with-pic 
		--prefix="$(dirname "${freeswitch_config[sys_path]}")"
	
	# 编译 spandsp
	make -j$(nproc) || {
		echo "[ERROR] spandsp源码编译失败,请检查!"
		return 3
	}
	
	# 安装 spandsp
	make install || {
		echo "[ERROR] spandsp安装失败,请检查!"
		return 4
	}
	
	# 设置临时环境变量
	export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
	
	# 永久生效
	echo "export PKG_CONFIG_PATH=\"/usr/local/lib/pkgconfig:\$PKG_CONFIG_PATH\"" >> /etc/profile
	
	# 确保动态库路径生效
	echo "/usr/local/lib" >> /etc/ld.so.conf
	ldconfig
	
	# 清理源码
	rm -rf "$path"
	return 0
}

# 编译 signalwire-c 源码
build_signalwire-c_source()
{
	# 获取 signalwire-c 源码路径
	local path=$(jq -r '.path // empty' <<< "${freeswitch_sources[signalwire-c]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		echo "[ERROR] 获取 signalwire-c 源码路径失败! ($path)"
		return 1
	fi
	
	cd "$path"
	
	# 配置 CMake
	cmake . -DCMAKE_INSTALL_PREFIX:PATH="$(dirname "${freeswitch_config[sys_path]}")" -DCMAKE_BUILD_TYPE=Release || {
		echo "[ERROR] signalwire-c源码CMake配置失败,请检查!"
		return 2
	}
	
	# 编译 signalwire-c
	make -j$(nproc) || {
		echo "[ERROR] signalwire-c源码编译失败,请检查!"
		return 3
	}
	
	# 安装 signalwire-c
	make install || {
		echo "[ERROR] signalwire-c安装失败,请检查!"
		return 4
	}
	
	# 清理源码
	rm -rf "$path"
	return 0
}

# 编译 freeswitch 源码
build_freeswitch_source()
{
	# 获取 signalwire-c 源码路径
	local path=$(jq -r '.path // empty' <<< "${freeswitch_sources[freeswitch]}" 2>/dev/null || echo '{}')
	if [ ! -d "$path" ]; then
		echo "[ERROR] 获取 freeswitch 源码路径失败! ($path)"
		return 1
	fi
	
	cd "$path"
	
	# mod_av mod_verto mod_xml_curl mod_python
	sed -i 's|#formats/mod_shout|formats/mod_shout|' build/modules.conf.in
	sed -i '/^applications\/mod_signalwire$/s/^/#/' build/modules.conf.in
	
	# --sysconfdir=/etc --localstatedir=/var -with-python --with-erlang
	./bootstrap.sh -j
	
	# 配置 configure 源码编译环境
	./configure --enable-portable-binary \
				--prefix="${freeswitch_config[sys_path]}" \
				--sysconfdir="${freeswitch_config[etc_path]}" \
				--localstatedir="${freeswitch_config[data_path]}" \
				--with-gnu-ld \
				--with-openssl \
				--enable-core-odbc-support \
				--enable-zrtp \
				--disable-signalwire

	# 编译 freeswitch
	make -j$(nproc)|| {
		echo "[ERROR] freeswitch源码编译失败,请检查!"
		return 3
	}
	
	# 安装 freeswitch
	make install || {
		echo "[ERROR] freeswitch安装失败,请检查!"
		return 4
	}
	
	make sounds-install		# 安装所有语音提示音 (8kHz / 16kHz)
	make moh-install		# 安装所有音乐保持音
	
	#make hd-sounds-install  # 安装 HD 质量提示音 (16kHz)
	#make hd-moh-install 	# 安装 HD 质量保持音
	
	#make uhd-sounds-install # 安装 UHD 质量提示音 (Ultra HD, 48kHz)
	#make uhd-moh-install 	# 安装 UHD 质量保持音
	
	#make cd-sounds-install  # 安装 CD 质量提示音 (16-bit, 44.1kHz)
	#make cd-moh-install 	# 安装 CD 质量保持音 

	# 清理源码
	rm -rf "$path"
	return 0
}

# 编译 freeswitch 源码
setup_freeswitch_source()
{
	echo "[INFO] 编译${freeswitch_config[name]}源码"
	
	# 编译 libks 源码
	if ! build_libks_source; then
		return 1
	fi
	
	# 编译 sofia-sip 源码
	if ! build_sofia-sip_source; then
		return 2
	fi
	
	# 编译 spandsp 源码
	if ! build_spandsp_source; then
		return 3
	fi
	
	# 编译 signalwire-c 源码
	if ! build_signalwire-c_source; then
		return 4
	fi
	
	# 编译 freeswitch 源码
	if ! build_freeswitch_source; then
		return 5
	fi
	
	return 0
}

# 安装 freeswitch 环境
install_freeswitch_env()
{
	local arg=$1
	echo "[INFO] 安装${freeswitch_config[name]}服务"
	
	local target_dir="${freeswitch_config[sys_path]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "${target_dir}" ]; then
			local downloads_dir="${system_config[downloads_dir]}"
			
			# 获取 freeswitch 源码
			if ! fetch_freeswitch_source "${downloads_dir}"; then
				echo "[ERROR] 获取${freeswitch_config[name]}失败,请检查!" >&2
				return 2
			fi
			
			# 编译 freeswitch 源码
			if ! setup_freeswitch_source; then
				echo "[ERROR] 编译${freeswitch_config[name]}失败,请检查!" >&2
				return 3
			fi
			
			# 清理临时文件
			rm -rf "$downloads_dir/output"
		fi
	elif [ "$arg" = "config" ]; then
		if [ -d "${target_dir}" ]; then
		
			# 创建freeswitch符号链接
			install_binary "${freeswitch_config[bin_path]}/${freeswitch_config[name]}" "" "/usr/local/bin/${freeswitch_config[name]}"

			# 创建fs_cli符号链接
			install_binary "${freeswitch_config[bin_path]}/fs_cli" "" "/usr/local/bin/fs_cli"
		fi
	fi
	
	echo "[INFO] 编译${freeswitch_config[name]}完成!"
	return 0
}

# 设置配置文件变量
set_freeswitch_vars()
{
	echo "[INFO] 设置配置文件变量"
	
	local vars_conf="${freeswitch_config[etc_path]}/freeswitch/vars.xml"
	if [ -f "$vars_conf" ]; then
		modify_xml_config -f "$vars_conf" -m replace \
			-o '//X-PRE-PROCESS[@data="default_password=1234"]' \
			-n '<X-PRE-PROCESS cmd="set" data="default_password='"${freeswitch_config[passwd]}"'"/>' \
			-p after
			
		if [ -n "${freeswitch_config[external_ip]}" ]; then
			modify_xml_config -f "$vars_conf" -m insert \
				-o '//X-PRE-PROCESS[@data="domain=$${local_ip_v4}"]' \
				-n '<X-PRE-PROCESS cmd="set" data="local_ip_v4='"${freeswitch_config[external_ip]}"'"/>' \
				-p before
			
			# '"${freeswitch_config[external_ip]}"'
			modify_xml_config -f "$vars_conf" -m replace \
				-o '//X-PRE-PROCESS[@data="external_rtp_ip=stun:stun.freeswitch.org"]' \
				-n '<X-PRE-PROCESS cmd="set" data="external_rtp_ip=$${local_ip_v4}"/>' \
				-p after
				
			modify_xml_config -f "$vars_conf" -m replace \
				-o '//X-PRE-PROCESS[@data="external_sip_ip=stun:stun.freeswitch.org"]' \
				-n '<X-PRE-PROCESS cmd="set" data="external_sip_ip=$${local_ip_v4}"/>' \
				-p after
		fi	
	fi
	
	local event_socket_conf="${freeswitch_config[etc_path]}/freeswitch/autoload_configs/event_socket.conf.xml"
	if [ -f "$event_socket_conf" ]; then
		modify_xml_config -f "$event_socket_conf" -m update \
			-o '//param[@name="listen-ip"]' \
			-n 'value="0.0.0.0"'
		
		modify_xml_config -f "$event_socket_conf" -m update \
			-o '//param[@name="password"]' \
			-n 'value="ClueCon"'
	fi
	
	echo "[INFO] 完成配置文件(vars.xml)设置"
}

# 设置 freeswitch 配置
set_freeswitch_conf()
{
	echo "[INFO] 设置${freeswitch_config[name]}配置文件"
	
	# freeswitch 预设数据
	local target_dir="${system_config[conf_dir]}/data"
	local dest_dir="${system_config[data_dir]}"
	
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null; then
		mkdir -p "$dest_dir"
		
		#mv "$target_dir"/* "${system_config[data_dir]}"
		if rsync -av --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			rm -rf "$target_dir"
		fi
	fi
	
	# freeswitch 预设配置
	target_dir="${system_config[conf_dir]}/etc"
	dest_dir="${system_config[config_dir]}"
	
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null; then
		mkdir -p "$dest_dir"
		
		#mv "$target_dir"/* "${system_config[config_dir]}"
		if rsync -av --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			rm -rf "$target_dir"
		fi
	fi
	
	# 设置配置文件变量
	set_freeswitch_vars
	
	echo "[INFO] 设置${freeswitch_config[name]}配置完成!"
}

# 设置 freeswitch 用户
set_freeswitch_user()
{
	echo "[INFO] 设置${freeswitch_config[name]}用户权限"

	chown -R ${user_config[user]}:${user_config[group]} \
			"${freeswitch_config[sys_path]}" \
			"${system_config[config_dir]}"
	
	echo "[INFO] 设置${freeswitch_config[name]}权限完成!"
}

# 设置 freeswitch 环境
set_freeswitch_env()
{
	local arg=$1
	echo "[INFO] 设置${freeswitch_config[name]}服务配置"
	
	if [ "$arg" = "config" ]; then	
		# 设置 freeswitch 配置
		set_freeswitch_conf
		
		# 设置 freeswitch 用户
		set_freeswitch_user
	fi
	
	echo "[INFO] 设置${freeswitch_config[name]}完成!"
	return 0
}

# 初始化 freeswitch 环境
init_freeswitch_service()
{
	local arg=$1
	echo "[INFO] 初始化${freeswitch_config[name]}服务"
	
	# 编译 freeswitch 源码
	if ! install_freeswitch_env "$arg"; then
		return 1
	fi
	
	# 设置 freeswitch 环境
	if ! set_freeswitch_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${freeswitch_config[name]}服务成功!"
	return 0
}

# 运行 freeswitch 服务
run_freeswitch_service()
{
	echo "[INFO] 运行${freeswitch_config[name]}服务"
	
	if [[ ! -e "${freeswitch_config[bin_path]}/freeswitch" || ! -e "${freeswitch_config[bin_path]}/fs_cli" ]]; then
		echo "[ERROR] ${freeswitch_config[name]}服务运行失败,请检查!" >&2
		return
	fi
	
	# 标识文件
	local pid_file="${freeswitch_config[run_path]}/${freeswitch_config[name]}.pid"
	
	# 检查服务是否已运行
	if [ -f "$pid_file" ]; then
		local pid=$(cat "$pid_file" 2>/dev/null)
		if ! kill -0 "$pid" >/dev/null 2>&1; then
			rm -f "$pid_file"
		else
			if ! grep -qF "${freeswitch_config[name]}" "/proc/$pid/cmdline" 2>/dev/null; then
				rm -f "$pid_file"
			else
				echo "[WARNING] ${freeswitch_config[name]}服务已经在运行(PID:$pid), 请检查!" >&2
				return 0
			fi
		fi
	fi
	
	# 后台运行 freeswitch
	nohup ${freeswitch_config[bin_path]}/freeswitch -nonat -nc >/dev/null 2>&1 &
	
	# 等待 PID 生效
	if ! wait_for_pid 10 "$pid_file"; then
		return 1
	fi
	
	echo "[INFO] 启动${freeswitch_config[name]}服务成功!"
}

# 停止 freeswitch 服务
close_freeswitch_service()
{
	echo "[INFO] 关闭${freeswitch_config[name]}服务"
	
	if [ ! -e "${freeswitch_config[bin_path]}/freeswitch" ]; then
		echo "[ERROR] ${freeswitch_config[name]}服务不存在,请检查!" >&2
		return
	fi
	
	# 标识文件
	local pid_file="${freeswitch_config[run_path]}/${freeswitch_config[name]}.pid"
	
	# 检查 freeswitch 服务进程
	if [ -e "$pid_file" ]; then
		for PID in $(cat "$pid_file" 2>/dev/null); do
			echo "[INFO] ${freeswitch_config[name]}服务进程: ${PID}"
			kill $PID
		done
		
		rm -rf "$pid_file"
	fi
	
	for PID in $(pidof ${freeswitch_config[name]}); do
		echo "[INFO] ${freeswitch_config[name]}服务进程:$PID"
		kill "$PID"
	done
	
	echo "[INFO] 关闭${freeswitch_config[name]}服务成功!"
}