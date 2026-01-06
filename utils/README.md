
# 模块结构设计
```
/app/bin/docker/
├── utils/                      # 共享工具模块目录
│   ├── lib/                    # 工具库目录
│   │   ├── archive_utils.sh    # 压缩包处理
│   │   ├── config_utils.sh     # 配置管理
│   │   ├── cron_utils.sh       # 定时任务
│   │   ├── download_utils.sh   # 下载功能
│   │   ├── git_utils.sh        # Git操作
│   │   ├── github_utils.sh     # GitHub API操作
│   │   ├── log_utils.sh        # 日志功能
│   │   ├── network_utils.sh    # 网络功能
│   │   ├── system_utils.sh     # 系统配置
│   │   └── version_utils.sh    # 版本比较
│   ├── feature.sh              # 脚本入口
│   ├── README.md               # 使用说明
└── └── docker-compose.yml      # 全局docker compose
```