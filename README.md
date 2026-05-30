# mysql-archive

为 macOS 预编译的 MySQL 二进制包，支持 Intel (x86_64) 和 Apple Silicon (arm64)。

## 触发构建

```bash
git tag v202605301603
git push
git push origin v202605301603
```

构建完成后，GitHub Release 页面会自动发布全部支持版本在 arm64 与 x86_64 两个目标架构上的二进制包。

## 支持版本

| 系列 | 最新版本 | 类型 |
|------|---------|------|
| 8.0 | 8.0.41 | Long-Term Support |
| 8.4 | 8.4.4 | Long-Term Support |

## 构建环境

| 架构 | Runner | 最低 macOS |
|------|--------|-----------|
| x86_64 (Intel) | `macos-14` | 12.0 Monterey |
| arm64 (Apple Silicon) | `macos-14` | 12.0 Monterey |

说明：由于 GitHub Actions 已不再稳定提供 `macos-13`，x86_64 产物改为在 `macos-14` Apple Silicon runner 上通过 Rosetta 与 x86_64 Homebrew 依赖链进行交叉编译。

## 构建配置

- **SSL**: OpenSSL 3.x
- **默认字符集**: `utf8mb4` / `utf8mb4_0900_ai_ci`
- **单元测试**: 禁用
- **jemalloc**: 禁用
- **Boost**: MySQL 8.0 在配置阶段自动下载；MySQL 8.4 已内置于源码
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
