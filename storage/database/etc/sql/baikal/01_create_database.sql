\echo '创建数据库...'

-- 创建角色
DO $$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'baikal') THEN
		CREATE ROLE baikal WITH
			LOGIN
			NOSUPERUSER
			NOCREATEDB
			NOCREATEROLE
			INHERIT
			NOREPLICATION
			CONNECTION LIMIT -1
			PASSWORD '123456';
		RAISE NOTICE '✓ 角色 baikal 创建成功';
	ELSE
		ALTER ROLE baikal WITH PASSWORD '123456';
		RAISE NOTICE '✓ 角色 baikal 密码已更新';
	END IF;
EXCEPTION
	WHEN insufficient_privilege THEN
		RAISE EXCEPTION '❌ 权限不足, 无法创建/修改角色!';
	WHEN OTHERS THEN
		RAISE EXCEPTION '❌ 创建角色失败! %', SQLERRM;
END $$;

DO $$
BEGIN
	IF EXISTS (SELECT FROM pg_database WHERE datname = 'baikal') THEN
		RAISE NOTICE '⚠ 数据库 baikal 已存在';
	END IF;
END $$;

-- 创建数据库
SELECT 'CREATE DATABASE baikal WITH 
	OWNER = baikal
	ENCODING = ''UTF8''
	LC_COLLATE = ''en_US.UTF-8''
	LC_CTYPE = ''en_US.UTF-8''
	TABLESPACE = pg_default
	CONNECTION LIMIT = -1
	IS_TEMPLATE = False
	TEMPLATE = template0;'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'baikal')\gexec

-- 验证数据库
DO $$
BEGIN
	IF EXISTS (SELECT FROM pg_database WHERE datname = 'baikal') THEN
		RAISE NOTICE '✓ 数据库 baikal 创建成功';
	ELSE
		RAISE WARNING '⚠ 数据库创建失败!';
	END IF;
END $$;