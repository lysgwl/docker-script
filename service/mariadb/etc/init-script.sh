#!/bin/bash
set -e

# 启动 MariaDB 的安全模式，且关闭网络监听
mysqld_safe --user=mysql --skip-networking &

# 等待MariaDB服务完全启动
until mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent; do
	sleep 1
done

# 遍历初始化目录中的所有SQL文件
for sql in /docker-entrypoint-initdb.d/*.sql; do
	if [ -f "$sql" ]; then
		# 执行SQL文件
		mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "$sql" || {
			echo "[错误] 脚本执行失败: $sql"
			exit 1
		}
	fi
done

# 关闭安全初始化模式的MariaDB实例
mysqladmin -uroot -p"$MYSQL_ROOT_PASSWORD" shutdown

# 启动 MariaDB 正式服务
exec mysqld \
	--user=mysql \
	--transaction-isolation=READ-COMMITTED \
	--character-set-server=utf8mb4 \
	--collation-server=utf8mb4_unicode_ci \
	--max-connections=512 \
	--innodb-rollback-on-timeout=OFF \
	--innodb-lock-wait-timeout=50 \
	--innodb_buffer_pool_size=512M \
	--innodb_log_file_size=512M