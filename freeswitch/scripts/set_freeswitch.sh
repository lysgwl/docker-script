#!/bin/bash

# freeswitch配置数组
declare -A freeswitch_config=(
	["name"]="freeswitch"
	["passwd"]="123456"
	["sys_path"]="/usr/local/freeswitch"
	["etc_path"]="${system_config[config_dir]}"
	["data_path"]="${system_config[data_dir]}"
	["bin_path"]="/usr/local/freeswitch/bin"
	["external_ip"]="$(echo "${EXTERNAL_IP:-}" | tr -d '"')"
)

# freeswitch源码数组
declare -A freeswitch_sources=(
	["libks"]='{"repo":"signalwire/libks", "version":"latest"}'
	["sofia-sip"]='{"repo":"freeswitch/sofia-sip", "version":"latest"}'
	["spandsp"]='{"repo":"freeswitch/spandsp", "version":"0d2e6ac65e0e8f53d652665a743015a88bf048d4"}'
	["signalwire-c"]='{"repo":"signalwire/signalwire-c", "version":"latest"}'
	["freeswitch"]='{"repo":"signalwire/freeswitch", "version":"latest"}'
)

readonly -A freeswitch_config

# 获取freeswitch源码
fetch_freeswitch_source()
{
	local downloads_dir=$1
	echo "[INFO] 获取${freeswitch_config[name]}源码" >&2
	
	local output_dir="${downloads_dir}/output"
	if [ ! -d "$output_dir" ]; then
		mkdir -p "$output_dir"
	fi
	
	local ret=0
	for key in "${!freeswitch_sources[@]}"; do
		local name="$key"
		local source_config="${freeswitch_sources[$name]}"
		
		# 解析JSON配置
		local repo=$(jq -r '.repo' <<< "$source_config")
		local version=$(jq -r '.version' <<< "$source_config")
		
		local url="https://github.com/$repo.git"
		echo "[INFO] 正在获取$name源码..." >&2
		
		local findpath latest_path
		if ! findpath=$(find_latest_archive "$downloads_dir" "$name.*"); then
			echo "[WARNING] 未匹配到$name软件包..." >&2
			
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
			
			local clone_path
			if ! clone_path=$(clone_repo "$json_config" "$downloads_dir"); then
				ret=2; break
			fi
			
			local clone_name=$(basename "$clone_path")
			if [ ! -d "$output_dir/$clone_name" ]; then
				# cp -rf "$clone_path" "$output_dir"
				rsync -a "$clone_path" "$output_dir"/
			fi
			
			latest_path="$output_dir/$clone_name"
		else
			local archive_type=$(jq -r '.filetype' <<< "$findpath")
			local archive_path=$(jq -r '.filepath' <<< "$findpath")
			
			if [[ -z "$archive_type" ]] || ! [[ "$archive_type" =~ ^(file|directory)$ ]]; then
				ret=1; break
			fi
			
			if [ "$archive_type" = "file" ]; then
				if ! latest_path=$(extract_and_validate "$archive_path" "$output_dir" "$name.*"); then
					ret=3; break
				fi
			else
				local archive_name=$(jq -r '.name' <<< "$findpath")
				if [ ! -d "$output_dir/$archive_name" ]; then
					# cp -rf "$archive_path" "$output_dir"
					rsync -a "$archive_path" "$output_dir"/
				fi
				
				latest_path="$output_dir/$archive_name"
			fi
		fi
		
		freeswitch_sources[$key]=$(jq --arg path "$latest_path" '. + {path: $path}' <<< "$source_config")
	done 
	
	return $ret
}

# 编译libks源码
build_libks_source()
{
	# 编译libks源码
	local json_config="${freeswitch_sources[libks]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] libks源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] libks源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"
	
	# 配置CMake	-DWITH_LIBBACKTRACE=1
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=Release || {
		echo "[ERROR] libks源码CMake配置失败,请检查!"
		return 2
	}
	
	# 编译libks
	make -j$(nproc) || {
		echo "[ERROR] libks源码编译失败,请检查!"
		return 3
	}
	
	# 安装libks
	make install || {
		echo "[ERROR] libks安装失败,请检查!"
		return 4
	}
	
	return 0
}

# 编译sofia-sip源码
build_sofia-sip_source()
{
	local json_config="${freeswitch_sources[sofia-sip]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] sofia-sip源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] sofia-sip源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"
	
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" --with-pic --with-glib=no --without-doxygen --disable-stun --prefix=/usr/local
	
	# 编译sofia-sip
	make -j$(nproc) || {
		echo "[ERROR] sofia-sip源码编译失败,请检查!"
		return 3
	}
	
	# 安装sofia-sip
	make install || {
		echo "[ERROR] sofia-sip安装失败,请检查!"
		return 4
	}
	
	return 0
}

# 编译spandsp源码
build_spandsp_source()
{
	local json_config="${freeswitch_sources[spandsp]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] spandsp源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] spandsp源码路径不存在:$path"
		return 1
	fi
	
	# git clone https://github.com/freeswitch/spandsp.git
	# git checkout -b compatible_version 0d2e6ac65e0e8f53d652665a743015a88bf048d4
	
	cd "$path"
	
	./bootstrap.sh
	./configure CFLAGS="-g -ggdb" --with-pic --prefix=/usr/local
	
	# 编译spandsp
	make -j$(nproc) || {
		echo "[ERROR] spandsp源码编译失败,请检查!"
		return 3
	}
	
	# 安装spandsp
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
	
	return 0
}

# 编译signalwire-c源码
build_signalwire-c_source()
{
	local json_config="${freeswitch_sources[signalwire-c]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] signalwire-c源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] signalwire-c源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"; 
	
	# 配置CMake
	cmake . -DCMAKE_INSTALL_PREFIX:PATH=/usr/local -DCMAKE_BUILD_TYPE=Release || {
		echo "[ERROR] signalwire-c源码CMake配置失败,请检查!"
		return 2
	}
	
	# 编译signalwire-c
	make -j$(nproc) || {
		echo "[ERROR] signalwire-c源码编译失败,请检查!"
		return 3
	}
	
	# 安装signalwire-c
	make install || {
		echo "[ERROR] signalwire-c安装失败,请检查!"
		return 4
	}
	
	return 0
}

# 编译freeswitch源码
build_freeswitch_source()
{
	local json_config="${freeswitch_sources[freeswitch]}"
	if [ -z "$json_config" ]; then
		echo "[ERROR] freeswitch源码配置存在问题,请检查!"
		return 1
	fi
	
	local path=$(jq -r '.path' <<< "$json_config")
	if [ ! -d "$path" ]; then
		echo "[ERROR] freeswitch源码路径不存在:$path"
		return 1
	fi
	
	cd "$path"
	sed -i 's|#formats/mod_shout|formats/mod_shout|' build/modules.conf.in
	
	# --sysconfdir=/etc --localstatedir=/var -with-python --with-erlang
	./bootstrap.sh -j
	
	./configure --enable-portable-binary \
				--prefix=/usr/local/freeswitch \
				--sysconfdir="${freeswitch_config[etc_path]}" \
				--localstatedir="${freeswitch_config[data_path]}" \
				--with-gnu-ld \
				--with-openssl \
				--enable-core-odbc-support \
				--enable-zrtp

	# 编译freeswitch
	make -j$(nproc)|| {
		echo "[ERROR] freeswitch源码编译失败,请检查!"
		return 3
	}
	
	# 安装sfreeswitch
	make install || {
		echo "[ERROR] freeswitch安装失败,请检查!"
		return 4
	}

	return 0
}

# 编译freeswitch源码
setup_freeswitch_source()
{
	echo "[INFO] 编译${freeswitch_config[name]}源码"
	
	# 编译libks源码
	if ! build_libks_source; then
		return 1
	fi
	
	# 编译sofia-sip源码
	if ! build_sofia-sip_source; then
		return 2
	fi
	
	# 编译spandsp源码
	if ! build_spandsp_source; then
		return 3
	fi
	
	# 编译signalwire-c源码
	if ! build_signalwire-c_source; then
		return 4
	fi
	
	# 编译freeswitch源码
	if ! build_freeswitch_source; then
		return 5
	fi
	
	return 0
}

# 安装freeswitch环境
install_freeswitch_env()
{
	local arg=$1
	echo "[INFO] 安装${freeswitch_config[name]}服务..."
	
	local install_dir="${system_config[install_dir]}"
	local downloads_dir="${system_config[downloads_dir]}"
	
	local target_dir="${freeswitch_config[sys_path]}"
	if [ "$arg" = "init" ]; then
		if [ ! -d "${target_dir}" ]; then
			# 获取freeswitch源码
			if ! fetch_freeswitch_source "${downloads_dir}"; then
				echo "[ERROR] 获取${freeswitch_config[name]}失败,请检查!"
				return 2
			fi
			
			# 编译freeswitch源码
			if ! setup_freeswitch_source; then
				echo "[ERROR] 编译${freeswitch_config[name]}失败,请检查!"
				return 3
			fi
		fi
	elif [ "$arg" = "config" ]; then
		if [ -d "${target_dir}" ]; then
			# 可执行文件
			install_binary "${freeswitch_config[bin_path]}/${freeswitch_config[name]}" "" "/usr/local/bin/${freeswitch_config[name]}"
			install_binary "${freeswitch_config[bin_path]}/fs_cli" "" "/usr/local/bin/fs_cli"
		fi
	fi
	
	echo "[INFO] 编译${freeswitch_config[name]}完成!"
	return 0
}

# 设置配置文件变量
set_freeswitch_vars()
{
	echo "设置配置文件变量"
	
	local vars_conf="${freeswitch_config[etc_path]}/freeswitch/vars.xml"
	if [ -f "$vars_conf" ]; then
		modify_xml_config -f "$vars_conf" -m insert \
			-o '//X-PRE-PROCESS[@data="domain=$${local_ip_v4}"]' \
			-n '<X-PRE-PROCESS cmd="set" data="local_ip_v4=auto"/>' \
			-p before
			
		modify_xml_config -f "$vars_conf" -m replace \
			-o '//X-PRE-PROCESS[@data="default_password=1234"]' \
			-n '<X-PRE-PROCESS cmd="set" data="default_password='"${freeswitch_config[passwd]}"'"/>' \
			-p after
			
		if [ -n "${freeswitch_config[external_ip]}" ]; then
			modify_xml_config -f "$vars_conf" -m replace \
				-o '//X-PRE-PROCESS[@data="external_rtp_ip=stun:stun.freeswitch.org"]' \
				-n '<X-PRE-PROCESS cmd="set" data="external_rtp_ip='"${freeswitch_config[external_ip]}"'"/>' \
				-p after
				
			modify_xml_config -f "$vars_conf" -m replace \
				-o '//X-PRE-PROCESS[@data="external_sip_ip=stun:stun.freeswitch.org"]' \
				-n '<X-PRE-PROCESS cmd="set" data="external_sip_ip='"${freeswitch_config[external_ip]}"'"/>' \
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
			-n 'value="'"${freeswitch_config[passwd]}"'"'	# "value=\"${freeswitch_config[passwd]}\""
	fi
	
	echo "完成配置文件(vars.xml)设置"
}

# 设置freeswitch配置
set_freeswitch_conf()
{
	echo "设置${freeswitch_config[name]}配置文件"
	
	# freeswitch预设数据
	local target_dir="${system_config[conf_dir]}/data"
	local dest_dir="${system_config[data_dir]}"
	
	if [[ -d "$target_dir" ]] && find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null; then
		mkdir -p "$dest_dir"
		
		#mv "$target_dir"/* "${system_config[data_dir]}"
		if rsync -av --remove-source-files "$target_dir"/ "$dest_dir"/ >/dev/null; then
			rm -rf "$target_dir"
		fi
	fi
	
	# freeswitch预设配置
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
	
	echo "设置${freeswitch_config[name]}配置完成!"
}

# 设置freeswitch用户
set_freeswitch_user()
{
	echo "设置${freeswitch_config[name]}用户权限..."

	chown -R ${user_config[user]}:${user_config[group]} "${freeswitch_config[sys_path]}"
	chmod 750 "${freeswitch_config[sys_path]}" 
		
	echo "设置${freeswitch_config[name]}权限完成!"
}

# 设置freeswitch环境
set_freeswitch_env()
{
	local arg=$1
	echo "设置${freeswitch_config[name]}服务配置..."
	
	if [ "$arg" = "config" ]; then	
		# 设置freeswitch配置
		set_freeswitch_conf
		
		# 设置freeswitch用户
		set_freeswitch_user
	fi
	
	echo "设置${freeswitch_config[name]}完成!"
	return 0
}

# 初始化freeswitch环境
init_freeswitch_env()
{
	local arg=$1
	echo "[INFO] 初始化${freeswitch_config[name]}服务..."
	
	# 编译freeswitch源码
	if ! install_freeswitch_env "$arg"; then
		return 1
	fi
	
	# 设置freeswitch环境
	if ! set_freeswitch_env "$arg"; then
		return 1
	fi
	
	echo "[INFO] 初始化${freeswitch_config[name]}服务成功!"
	return 0
}

# 运行freeswitch服务
run_freeswitch_service()
{
	echo "[INFO] 运行${freeswitch_config[name]}服务..."
	
	if [[ ! -e "${freeswitch_config[bin_path]}/freeswitch" || ! -e "${freeswitch_config[bin_path]}/fs_cli" ]]; then
		echo "[ERROR] ${freeswitch_config[name]}服务运行失败,请检查!"
		return
	fi
	
	# 检查服务是否已运行
	if pgrep -f "${freeswitch_config[name]}" > /dev/null; then
		echo "[WARNING] ${freeswitch_config[name]}服务已经在运行!"
		return
	fi
	
	# 后台运行nginx
	nohup ${freeswitch_config[bin_path]}/freeswitch -nonat -nc >/dev/null 2>&1 &
	
	# 等待 2 秒
	sleep 2
	
	echo "[INFO] 启动${freeswitch_config[name]}服务成功!"
}

# 停止freeswitch服务
close_freeswitch_service()
{
	echo "[INFO] 关闭${freeswitch_config[name]}服务..."
	
	if [ ! -e "${freeswitch_config[bin_path]}/freeswitch" ]; then
		echo "[ERROR] ${freeswitch_config[name]}服务不存在,请检查!"
		return
	fi
	
	for PID in $(pidof ${freeswitch_config[name]}); do
		echo "[INFO] ${freeswitch_config[name]}服务进程:${PID}"
		kill $PID
	done
	
	echo "[INFO] 关闭${freeswitch_config[name]}服务成功!"
}