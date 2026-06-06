# mysql-archive

为 macOS、Linux、Windows 预编译的 MySQL 二进制包，支持 Intel (x86_64) 和 Apple Silicon / ARM (arm64)。

## 触发构建

```bash
git tag v202606061712
git push
git push origin v202606061712
```

构建完成后，GitHub Release 页面会自动发布全部支持版本在所有平台与架构上的二进制包。

## 支持版本

| 系列 | 最新版本 | 类型 |
|------|---------|------|
| 9.6 | 9.6.0 | Innovation |
| 8.4 | 8.4.7 | Long-Term Support |
| 5.7 | 5.7.44 | End of Life |

## 构建矩阵

每个 **操作系统 × 架构 × MySQL 版本** 组合为独立的 CI job，共 15 个 job：

| 操作系统 | 架构 | Runner |
|---------|------|--------|
| macOS | arm64 | `macos-14` |
| macOS | x86_64 | `macos-14`（Rosetta 交叉编译）|
| Linux | arm64 | `ubuntu-24.04-arm` |
| Linux | x86_64 | `ubuntu-24.04` |
| Windows | arm64 | `windows-11-arm` |
| Windows | x86_64 | `windows-latest` |

## 构建配置

- **SSL**: OpenSSL 3.x
- **默认字符集**: `utf8mb4` / `utf8mb4_0900_ai_ci`
- **单元测试**: 禁用
- **jemalloc**: 禁用
- **Boost**: MySQL 5.7 在配置阶段自动下载；MySQL 8.4 / 9.6 使用源码内置 Boost
- **源码**: 从 [cdn.mysql.com](https://cdn.mysql.com/Downloads/) 下载

## 使用方法

从 [Releases](../../releases) 页面下载对应架构的压缩包：

```bash
# 解压
tar xzf mysql-VERSION-macos-ARCH.tar.gz
cd mysql-VERSION-macos-ARCH

# 初始化数据目录（首次使用）
# 初始化完成后，临时 root 密码会打印到终端，请妥善记录
mkdir data
./bin/mysqld --initialize --datadir=$(pwd)/data --basedir=$(pwd)

# 启动服务
./bin/mysqld --datadir=$(pwd)/data --basedir=$(pwd) \
  --socket=/tmp/mysql.sock --port=3306 &

# 连接（使用初始化时生成的临时密码）
./bin/mysql -u root -p --socket=/tmp/mysql.sock

# 首次登录后修改密码
ALTER USER 'root'@'localhost' IDENTIFIED BY 'your_new_password';

# 关闭服务
./bin/mysqladmin -u root -p --socket=/tmp/mysql.sock shutdown
```

## 校验文件完整性

每个压缩包附带 SHA256 校验文件：

```bash
shasum -a 256 -c mysql-VERSION-macos-ARCH.tar.gz.sha256
```

## CI 构建说明

仓库包含一个 GitHub Actions 工作流（`.github/workflows/build.yml`），实现了 "一平台 + 一 MySQL 版本 = 一个 job" 的策略。

- 触发方式：推送 tag（例如 `git tag v202605301603 && git push --tags`）或手动通过 Actions 的 `workflow_dispatch`。
- 每个组合会生成独立的 job，job 名称形如 `Build - <arch> - MySQL <version>`。
- 目前 workflow 中的步骤为占位实现：下载源码、按架构选择 Rosetta（x86_64）等，实际的 configure / make / 打包步骤请根据你的构建脚本替换 `Build (placeholder)` 步骤。

如果需要，我可以把占位步骤替换为具体的构建脚本（包含 Homebrew 依赖、交叉编译技巧、产物打包与签名）。
