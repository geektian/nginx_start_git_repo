#!/usr/bin/env bash
#
# 一键安装 Git、Nginx（若未安装）并创建 Git bare 仓库 + post-receive 钩子实现自动部署
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
  echo "如果你以普通用户运行，后续 'apt-get'/'yum' 安装会失败。"
  exit 1
fi

#---------------------------
# 1) 检测/安装 Git
#---------------------------
echo "==> 检测是否已安装 Git..."
if command -v git &> /dev/null; then
  echo "Git 已安装，跳过安装步骤。"
else
  echo "Git 未安装，开始自动安装..."

  # 优先检测 apt-get
  if command -v apt-get &> /dev/null; then
    echo "使用 apt-get 安装 Git..."
    apt-get update
    apt-get install -y git

  # 若无 apt-get，再检测 yum/dnf
  elif command -v yum &> /dev/null; then
    echo "使用 yum 安装 Git..."
    yum install -y git
  elif command -v dnf &> /dev/null; then
    echo "使用 dnf 安装 Git..."
    dnf install -y git
  else
    echo "错误：未检测到 apt-get 或 yum/dnf，无法自动安装 Git。请手动安装后再运行本脚本。"
    exit 1
  fi

  echo "Git 安装完成。"
fi

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
# 6) 写入 post-receive 钩子
#---------------------------
HOOK_FILE="$BARE_REPO_DIR/hooks/post-receive"
echo "==> 写入 post-receive 钩子到 $HOOK_FILE"

cat << 'EOF' > "$HOOK_FILE"
#!/usr/bin/env bash
#
# post-receive Hook: 在收到 push 后自动将代码检出到 /srv/myproject-deploy
# 然后将 Nginx 配置、证书等同步到系统目录，最后重载 Nginx

set -e

# 与脚本中的路径保持一致
WORK_TREE="/srv/myproject-deploy"
GIT_DIR="/home/git/myproject.git"

echo "[post-receive] 开始部署..."

echo "[post-receive] 检出最新提交到 $WORK_TREE..."
git --work-tree="$WORK_TREE" --git-dir="$GIT_DIR" checkout -f

# 根据你项目的文件结构进行同步
# 以下假设在仓库中放置了：
#   - nginx.conf
#   - conf.d/ (存放各站点 .conf)
#   - ssl/    (存放证书)
# 若有需要同步的网站文件，如 /var/www/html/，可自行添加 rsync 命令

if [ -f "$WORK_TREE/nginx.conf" ]; then
  echo "[post-receive] 同步 nginx.conf 到 /etc/nginx/nginx.conf"
  rsync -avz --delete "$WORK_TREE/nginx.conf" /etc/nginx/nginx.conf
fi

if [ -d "$WORK_TREE/conf.d" ]; then
  echo "[post-receive] 同步 conf.d/ 到 /etc/nginx/conf.d/"
  rsync -avz --delete "$WORK_TREE/conf.d/" /etc/nginx/conf.d/
fi

if [ -d "$WORK_TREE/ssl" ]; then
  echo "[post-receive] 同步 ssl/ 到 /etc/nginx/ssl/"
  mkdir -p /etc/nginx/ssl/
  rsync -avz --delete "$WORK_TREE/ssl/" /etc/nginx/ssl/
fi

# 如需同步网站文件到 /var/www/html/ 或 /srv/xxxx，可以添加:
# rsync -avz --delete "$WORK_TREE/www/" /var/www/html/

echo "[post-receive] 检查 Nginx 配置..."
nginx -t

echo "[post-receive] 重载 Nginx..."
systemctl reload nginx

echo "[post-receive] 部署完成！"
EOF

chmod +x "$HOOK_FILE"

#---------------------------
# 7) 确保 Nginx 处于启动状态
#---------------------------
echo "==> 启动并设置 Nginx 开机自启动..."
systemctl enable nginx
systemctl start nginx

#---------------------------
# 8) 提示信息
#---------------------------
echo "======================================================="
echo "✅ 已完成："
echo "  1) Git 安装 (若原先未安装)"
echo "  2) Nginx 安装 (若原先未安装)"
echo "  3) Bare 仓库初始化：$BARE_REPO_DIR"
echo "  4) post-receive 钩子配置并赋可执行权限"
echo "  5) Nginx 已启动/重载"
echo "======================================================="
echo "请在本地项目中执行以下操作，将代码推送到此服务器："
echo ""
echo "  git remote add production ssh://<SERVER_USER>@<SERVER_IP>$BARE_REPO_DIR"
echo "  # 如果你在脚本中使用的用户是 root，就写 root；如果是其他用户，就写对应用户名。"
echo ""
echo "  # 推送主分支到服务器 (视你的分支名称而定，如 main / master)"
echo "  git push production main"
echo ""
echo "推送成功后，服务器将自动检出到 $WORK_TREE_DIR 并重载 Nginx。"
echo "如需修改部署逻辑，请编辑：$HOOK_FILE"
echo "======================================================="

