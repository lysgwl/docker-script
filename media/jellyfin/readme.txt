# readme

1. TMDB 
	URL: https://www.themoviedb.org/
	API: NzBiN2MxNTBlODhlYThjZGRkMTk0MDNmNTNmYTgzODg
	
2. Bangumi
	URL: https://jellyfin-plugin-bangumi.pages.dev/repository.json
	
3. MetaShark 
	URL：https://ghfast.top/https://github.com/cxfksword/jellyfin-plugin-metashark/releases/download/manifest/manifest_cn.json
	jellyfin-cli					# 进入 Jellyfin 控制台
	jellyfin-cli metadata update	# 更新元数据
	
4. Jellyfin 刮削加速
	wget http://file.867678.xyz/patch/jellyfin/normal/net5.0-Linux-Release/System.Net.Http.dll -O /usr/lib/jellyfin/bin/System.Net.Http.dll
	systemctl restart jellyfin.service	
	
5. Danmu 弹幕
	URL：https://mirror.ghproxy.com/https://github.com/cxfksword/jellyfin-plugin-danmu/releases/download/manifest/manifest_cn.json	
	
6. MetaTube
	URL：https://raw.githubusercontent.com/metatube-community/jellyfin-plugin-metatube/dist/manifest.json	
	
7. command
	entrypoint: ["/bin/bash", "-c"]
	command: >
	  '
		# 复制配置文件
		if [ -f "/config/jellyfin.conf" ] && [ -d "/config/nginx/extra/proxy-config" ]; then
			cp -v "/config/jellyfin.conf" "/config/nginx/extra/proxy-config/"
		fi
		
		# 注册信号
		trap "
			[ -f \"/config/nginx/extra/proxy-config/jellyfin.conf\" ] && 
			rm -v \"/config/nginx/extra/proxy-config/jellyfin.conf\";
			exit 0
		" SIGTERM   # SIGTERM - 15
		
		# 启动主进程
		exec /jellyfin/jellyfin
	  '
8. 跳过片头插件
	URL：https://raw.githubusercontent.com/ConfusedPolarBear/intro-skipper/master/manifest.json