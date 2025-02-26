#!/usr/bin/env bash
#
# 一键安装 Git、Nginx、certbot（含 Cloudflare DNS 插件），配置 SSH 免密登录
# 创建 Git bare 仓库 + post-receive 钩子实现自动部署
# 更新 SSH 设置，允许 root 登录并清理 sshd_config.d
# 
# 作者：ChatGPT 示例
# 用法：
#   1) 以 root 或具备 sudo 权限的用户在服务器上执行
#   2) 若脚本报错，可根据提示修复权限或路径问题
#   3) 执行完后，本地项目推送到服务器的 bare 仓库即可触发自动部署

set -e

#---------------------------
# 0) 检查当前用户是否具备必要权限
#---------------------------
if [[ $EUID -ne 0 ]]; then
  echo "注意：请使用 root 或具备 sudo 权限的用户运行本脚本。"
  exit 1
fi

#---------------------------
# 1) 配置 SSH 免密登录 & 允许 root 远程登录
#---------------------------
echo "==> 配置 SSH 免密登录并允许 root 账户登录..."
SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA9Jj6U22HbB5ZAGI1fkUrF38um5Am/vI2nbxqrK///F1cCBQ72mCtq1fIeLnEJSALhPf+NFx7tlyo7q0wrjJYjIzst4LAOaplzG4aZx+FCVdP9meVwwLIXB/tSTLlIS0NmDoedqRllbZ7brYCIPqgx1fGMg5nkvAugnZyQ1rwUUE4c+OhHc4PAQuhF0vDdGIkORQw4CoUmHEQbny9tCd3NaXa+hzPvlGQTef1UWLZWTFWJyk4LFS042sKPDwUwr0tJI/w/J9P9bZv/K/voF+EDxwrBETzvt2ZdDo30JZo54pC5rTG4GTlvdKW00JBLGqxS8OJhNnE2y5KQ4rjVNAxlw== rsa 2048-20241202"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

# 修改 SSH 配置，允许 root 登录，禁用密码认证，启用公钥认证
echo "==> 修改 SSH 配置..."
sed -i 's/^#\?PasswordAuthentication\s.*/PasswordAuthentication no/g' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication\s.*/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin\s.*/PermitRootLogin yes/g' /etc/ssh/sshd_config

# 删除所有 /etc/ssh/sshd_config.d/ 配置文件，防止干扰
echo "==> 清理 /etc/ssh/sshd_config.d/ 目录..."
rm -rf /etc/ssh/sshd_config.d/*

# 重启 SSH 服务
echo "==> 重启 SSH 服务..."
systemctl restart sshd

echo "✅ SSH 免密登录和 root 账户登录配置完成！"

#---------------------------
# 2) 安装 Git、Certbot 及 Cloudflare 插件
#---------------------------
echo "==> 开始安装/更新 Git、Python 依赖及 Certbot（Python 虚拟环境方式）..."

###############################
# 1) 检测包管理器
###############################
INSTALL_CMD=""
REMOVE_CMD=""
PYTHON_DEPS=""
AUGEAS_LIB=""

if command -v apt-get &> /dev/null; then
  INSTALL_CMD="apt-get install -y"
  REMOVE_CMD="apt-get remove -y"
  PYTHON_DEPS="python3 python3-venv libaugeas0"
  AUGEAS_LIB="libaugeas0"
  apt-get update
elif command -v yum &> /dev/null; then
  INSTALL_CMD="yum install -y"
  REMOVE_CMD="yum remove -y"
  PYTHON_DEPS="python3 augeas-libs"  # 部分老版本可能需要改成 python36
  AUGEAS_LIB="augeas-libs"
elif command -v dnf &> /dev/null; then
  INSTALL_CMD="dnf install -y"
  REMOVE_CMD="dnf remove -y"
  PYTHON_DEPS="python3 augeas-libs"
  AUGEAS_LIB="augeas-libs"
else
  echo "❌ 未找到合适的包管理器 (apt-get / yum / dnf)，请手动安装 Git、Python3、Augeas 等依赖。"
  exit 1
fi

###############################
# 2) 安装 Git
###############################
echo "==> 检测是否已安装 Git..."
if ! command -v git &> /dev/null; then
  echo "Git 未安装，开始安装..."
  $INSTALL_CMD git
else
  echo "Git 已安装，跳过..."
fi

###############################
# 3) 安装 Python3 及相关依赖
###############################
echo "==> 安装 Certbot 所需的 Python3、venv、Augeas 等依赖..."
$INSTALL_CMD $PYTHON_DEPS

###############################
# 4) 卸载系统包管理器安装的 Certbot 及其插件（如有）
###############################
echo "==> 卸载系统中可能已存在的 Certbot 及其插件 (避免冲突)..."
# 尝试卸载 certbot 及常见插件包（如果未安装，则不会卸载任何内容）
$REMOVE_CMD certbot python3-certbot python3-certbot-nginx python3-certbot-dns-cloudflare 2>/dev/null || true

###############################
# 5) 在 /opt/certbot 下创建虚拟环境并安装 Certbot、插件
###############################
echo "==> 创建 Python 虚拟环境并安装 Certbot、Nginx 插件、Cloudflare 插件..."

# 如果 /opt/certbot 已存在且不是你想要的，可以先 rm -rf /opt/certbot
if [ ! -d "/opt/certbot" ]; then
  mkdir -p /opt/certbot
fi

# 创建虚拟环境
python3 -m venv /opt/certbot/

# 升级 pip
/opt/certbot/bin/pip install --upgrade pip

# 安装 certbot, certbot-nginx, certbot-dns-cloudflare
/opt/certbot/bin/pip install certbot certbot-nginx certbot-dns-cloudflare

# 升级 cloudflare
/opt/certbot/bin/pip install --upgrade cloudflare


###############################
# 6) 建立 certbot 命令软链接
###############################
echo "==> 创建 /usr/bin/certbot 软链接..."
if [ -L "/usr/bin/certbot" ] || [ -f "/usr/bin/certbot" ]; then
  rm -f /usr/bin/certbot
fi
ln -s /opt/certbot/bin/certbot /usr/bin/certbot

###############################
# 7) 安装 rsync
###############################
echo "==> 检测是否已安装 rsync..."
if ! command -v rsync &> /dev/null; then
  echo "rsync 未安装，开始安装..."
  $INSTALL_CMD rsync
else
  echo "rsync 已安装，跳过..."
fi

echo "✅ Git、Certbot（虚拟环境安装）及其插件安装完成！"
echo "==> 现在可以使用 'certbot' 命令来申请或管理证书了。"

#---------------------------
# 2) 检测/安装 Nginx
#---------------------------
echo "==> 检测是否已安装 Nginx..."
if command -v nginx &> /dev/null; then
  echo "Nginx 已安装，跳过安装步骤。"
else
  echo "Nginx 未安装，开始自动安装..."

  # 优先检测 apt-get
  if command -v apt-get &> /dev/null; then
    echo "使用 apt-get 安装 Nginx..."
    apt-get update
    apt-get install -y nginx

  # 若无 apt-get，再检测 yum/dnf
  elif command -v yum &> /dev/null; then
    echo "使用 yum 安装 Nginx..."
    yum install -y nginx
  elif command -v dnf &> /dev/null; then
    echo "使用 dnf 安装 Nginx..."
    dnf install -y nginx
  else
    echo "错误：未检测到 apt-get 或 yum/dnf，无法自动安装 Nginx。请手动安装后再运行本脚本。"
    exit 1
  fi

  echo "Nginx 安装完成。"
fi

#---------------------------
# 3) 定义相关路径，可根据需求修改
#---------------------------
BARE_REPO_DIR="/home/git/myproject.git"     # Bare 仓库目录
WORK_TREE_DIR="/srv/myproject-deploy"       # 工作目录，用于检出最新文件

#---------------------------
# 4) 创建 Bare 仓库并初始化
#---------------------------
echo "==> 创建 bare 仓库目录：$BARE_REPO_DIR"
mkdir -p "$BARE_REPO_DIR"
cd "$BARE_REPO_DIR"
if [ ! -d "objects" ]; then
  echo "==> 初始化 bare 仓库"
  git init --bare
else
  echo "该目录下已存在 Git 仓库，将继续使用。"
fi

#---------------------------
# 5) 创建工作目录（检出目录）
#---------------------------
echo "==> 创建/确认工作目录：$WORK_TREE_DIR"
mkdir -p "$WORK_TREE_DIR"


#---------------------------
# 4) post-receive 钩子配置
#---------------------------
HOOK_FILE="/home/git/myproject.git/hooks/post-receive"

cat << 'EOF' > "$HOOK_FILE"
#!/usr/bin/env bash
#
# post-receive Hook: 在收到 push 后自动同步 Nginx 配置并执行证书部署脚本
# 请将本脚本放于 /home/git/myproject.git/hooks/post-receive，并赋予可执行权限。

set -e

#---------------------------
# 1) 路径定义
#---------------------------
WORK_TREE="/srv/myproject-deploy"           # 工作区，检出后的文件存放处
GIT_DIR="/home/git/myproject.git"           # Bare 仓库

# 你的 Nginx 配置在仓库中的相对路径
NGINX_CONF_SRC="$WORK_TREE/nginx_conf/nginx.conf"
CONF_D_SRC="$WORK_TREE/nginx_conf/conf.d/"
SITES_SRC="$WORK_TREE/nginx_conf/sites/"



# 证书部署脚本 & cloudflare.ini
EXECUTE_SCRIPT="$WORK_TREE/execute_sh/deploy_certificates.sh"
CLOUDFLARE_INI_SRC="$WORK_TREE/execute_sh/cloudflare.ini"

# 同步到的系统路径
NGINX_CONF_DEST="/etc/nginx/nginx.conf"
CONF_D_DEST="/etc/nginx/conf.d/"
SITES_DEST="/etc/nginx/sites/"

# 先删除旧的文件，再检出新的站点
rm -rf "$SITES_DEST"

#---------------------------
# 2) 检出仓库内容到 WORK_TREE
#---------------------------
echo "[post-receive] 开始部署，检出最新提交..."
git --work-tree="$WORK_TREE" --git-dir="$GIT_DIR" checkout -f

#---------------------------
# 3) 确保目标目录都存在，避免 rsync 或 cp 出错
#---------------------------
echo "[post-receive] 确保必要目录存在..."
mkdir -p "$(dirname "$NGINX_CONF_DEST")"  # 确保 /etc/nginx/ 存在
mkdir -p "$CONF_D_DEST"
mkdir -p "$SITES_DEST"
mkdir -p "$WORK_TREE/execute_sh"

#---------------------------
# 4) 同步/覆盖 Nginx 配置文件
#---------------------------
echo "[post-receive] 检查并覆盖主配置 nginx.conf"
if [ -f "$NGINX_CONF_SRC" ]; then
  cp -f "$NGINX_CONF_SRC" "$NGINX_CONF_DEST"
  echo "  -> 已覆盖: $NGINX_CONF_DEST"
else
  echo "  ⚠️ 未找到 $NGINX_CONF_SRC，跳过覆盖主配置。"
fi

echo "[post-receive] 检查并覆盖 conf.d/"
if [ -d "$CONF_D_SRC" ]; then
  rsync -avz --delete "$CONF_D_SRC" "$CONF_D_DEST"
  echo "  -> 已同步: $CONF_D_DEST"
else
  echo "  ⚠️ 未找到 $CONF_D_SRC，跳过同步 conf.d。"
fi

echo "[post-receive] 检查并覆盖 sites/"
if [ -d "$SITES_SRC" ]; then
  rsync -avz --delete "$SITES_SRC" "$SITES_DEST"
  echo "  -> 已同步: $SITES_DEST"
else
  echo "  ⚠️ 未找到 $SITES_SRC，跳过同步 sites。"
fi

#---------------------------
# 5) 确保 cloudflare.ini 存在并复制到工作区
#---------------------------
if [ -f "$CLOUDFLARE_INI_SRC" ]; then
  echo "[post-receive] 复制 cloudflare.ini 到 $WORK_TREE/execute_sh/ ..."
else
  echo "  ⚠️ 未找到 $CLOUDFLARE_INI_SRC，跳过复制。"
fi

#---------------------------
# 6) 执行证书部署脚本
#---------------------------
if [ -f "$EXECUTE_SCRIPT" ]; then
  echo "[post-receive] 执行证书部署脚本: $EXECUTE_SCRIPT"
  bash "$EXECUTE_SCRIPT"
else
  echo "  ⚠️ 未找到 $EXECUTE_SCRIPT，跳过执行。"
fi

#---------------------------
# 7) 检查 Nginx 配置 & 重载
#---------------------------
echo "[post-receive] 检查 Nginx 配置..."
if nginx -t; then
  echo "✅ Nginx 配置检测通过，重载中..."
  systemctl reload nginx
else
  echo "❌ Nginx 配置错误，请查看日志！"
  exit 1
fi

echo "[post-receive] 🎉 部署完成！"

EOF

chmod +x "$HOOK_FILE"

echo "✅ post-receive 钩子配置完成！"

#---------------------------
# 5) 确保 Nginx 处于启动状态
#---------------------------
echo "==> 启动并设置 Nginx 开机自启动..."
systemctl enable nginx
systemctl start nginx

#---------------------------
# 6) 提示信息
#---------------------------
echo "======================================================="
echo "✅ 已完成："
echo "  1) SSH 免密登录配置"
echo "  2) 允许 root 远程登录"
echo "  3) 删除 /etc/ssh/sshd_config.d/ 配置文件"
echo "  4) Git 安装 (若原先未安装)"
echo "  5) certbot、python3-certbot-dns-cloudflare 安装"
echo "  6) Bare 仓库初始化"
echo "  7) post-receive 钩子配置并赋可执行权限"
echo "  8) Nginx 已启动/重载"
echo "======================================================="
