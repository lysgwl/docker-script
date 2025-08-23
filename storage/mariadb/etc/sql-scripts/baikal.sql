

-- 创建数据库
CREATE DATABASE IF NOT EXISTS `baikal`
	CHARACTER SET utf8mb4
	COLLATE utf8mb4_unicode_ci;
	
-- 创建用户
CREATE USER IF NOT EXISTS 'baikal'@'%'
	IDENTIFIED BY '123456';
	
-- 给用户授予该数据库的全部权限
GRANT ALL PRIVILEGES ON `baikal`.* TO 'baikal'@'%';

-- 使权限立即生效
FLUSH PRIVILEGES;