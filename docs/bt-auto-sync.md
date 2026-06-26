# 宝塔计划任务自动同步

## 用途

该计划任务只负责同步公网状态页。它不会部署 WireGuard，也不会生成或复制任何密钥、客户端配置和二维码。

## 推荐配置

- 任务类型：Shell 脚本
- 任务名称：`ChinaVPN-自动同步部署`
- 执行周期：每小时第 0 分钟开始，每隔 10 分钟执行一次
- 脚本内容：

```bash
bash /opt/chinavpn-public-site/scripts/bt-auto-sync-public-site.sh
```

## 首次安装

在服务器上执行一次：

```bash
mkdir -p /opt/chinavpn-public-site
git clone https://github.com/Mike-Zhuang/My_Own_VPN.git /opt/chinavpn-public-site
bash /opt/chinavpn-public-site/scripts/bt-auto-sync-public-site.sh
```

## 脚本行为

- 仓库副本保存到 `/opt/chinavpn-public-site`，不会放在网站根目录里。
- 网站根目录默认为 `/www/wwwroot/chinavpn.mikezhuang.cn`。
- 每次执行会拉取 `main` 分支最新代码。
- 执行敏感信息检查，通过后才同步 `public/`。
- 同步完成后写入 `deploy-info.txt`，方便确认当前部署版本。
- 所有关键步骤都会输出到标准输出，宝塔计划任务日志里可以直接查看。

## 可选环境变量

```bash
REPO_URL=https://github.com/Mike-Zhuang/My_Own_VPN.git
BRANCH=main
REPO_DIR=/opt/chinavpn-public-site
WEB_ROOT=/www/wwwroot/chinavpn.mikezhuang.cn
PUBLIC_DIR=public
```

## 安全边界

- 不要把仓库 clone 到 `/www/wwwroot/chinavpn.mikezhuang.cn`。
- 不要在计划任务里写 GitHub token、SSH 私钥或服务器密钥。
- 不要把 `client-configs/`、`server-secrets/`、`PLAN.md` 放进网站目录。
- 如果未来加入登录状态页，登录配置应放到服务器本地被忽略文件，不提交 Git。
