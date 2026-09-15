# Linux 服务备份与恢复脚本

这个仓库保存 Plex 和 Vaultwarden 的离线备份、恢复脚本。脚本会在备份时短暂停止服务，生成压缩包和相邻的 SHA-256 校验文件，并可通过 rclone 上传到远端。

## 脚本一览

| 脚本 | 适用场景 | 主要行为 |
| --- | --- | --- |
| [`plex-backup.sh`](./plex-backup.sh) | 通过 deb/rpm 直接安装、由 systemd 管理的 Plex | 停止正在运行的 Plex，备份应用数据，恢复原运行状态，可上传 rclone |
| [`plex-restore.sh`](./plex-restore.sh) | 在 Linux 上恢复原生安装的 Plex | 校验并替换 Plex 数据目录，成功后保持 Plex 停止 |
| [`vaultwarden-backup.sh`](./vaultwarden-backup.sh) | Docker 运行、使用 SQLite 的 Vaultwarden | 停止正在运行的容器，备份整个部署目录，恢复原运行状态，上传并清理旧备份 |
| [`vaultwarden-restore.sh`](./vaultwarden-restore.sh) | 在 Docker Compose 上恢复 SQLite Vaultwarden | 校验归档、数据库、Compose 和挂载后恢复；可选择启动或保持停止 |

## 运行要求

- GNU/Linux、Bash 4+、root 权限。
- Plex 脚本只支持直接安装并由 systemd 管理的 Plex，不适用于 Docker 版 Plex。
- Vaultwarden 脚本只支持 SQLite，不支持 MySQL 或 PostgreSQL。
- 备份上传需要已配置的 `rclone`；设置空的 `RCLONE_DEST` 可以只保留本地备份。
- Vaultwarden 恢复默认还需要 Python 3、SQLite 命令行工具和 Docker Compose。
- 脚本依赖常见 GNU 工具，以及 `flock`（通常由 `util-linux` 提供）。

本文后续服务器命令默认在 root shell 中执行。普通用户先运行：

```bash
sudo -i
```

Debian/Ubuntu 可先安装额外工具：

```bash
apt-get update
apt-get install -y git rclone sqlite3 python3
```

Plex Media Server、Docker 和 Docker Compose 请按各自的安装方式预先安装。

## 获取脚本

```bash
cd /root
git clone https://github.com/AtomBoyC/linux-scripts.git
cd linux-scripts
chmod +x ./*.sh
```

后续命令默认在 `sudo -i` 打开的 root shell 中执行，因此示例仓库路径为 `/root/linux-scripts`，rclone 配置也属于 root。所有自定义选项都通过环境变量传入。

如果不进入 root shell，而是逐条配合 `sudo` 执行脚本，应把变量放在 `sudo env` 后面：

```bash
sudo env KEY=value ./script.sh
```

## 配置 rclone

首次使用时配置并测试远端：

```bash
rclone config
rclone lsd 'NAtomJZXTR:'
```

两个备份脚本的默认目标不同：

| 脚本 | 默认远端 |
| --- | --- |
| Plex | `NAtomJZXTR:`，即远端根目录 |
| Vaultwarden | `NAtomJZXTR:vaultwarden-backups` |

建议给 Plex 指定单独目录：

```bash
RCLONE_DEST='NAtomJZXTR:plex-backups' ./plex-backup.sh
```

如果 rclone 配置不在当前 root 用户的默认位置，可以显式指定：

```bash
RCLONE_CONFIG='/path/to/rclone.conf' \
  ./vaultwarden-backup.sh
```

如果没有进入 root shell，Plex 备份脚本通过 `sudo` 执行且未指定 `RCLONE_CONFIG` 时，会尝试读取发起调用用户的标准 rclone 配置。Vaultwarden 备份脚本不会这样查找；逐条使用 `sudo` 时，应通过 `sudo env RCLONE_CONFIG=...` 显式传入配置路径。

备份中含数据库、账号配置、令牌和附件等敏感数据。rclone 普通远端不会自动加密文件；如需客户端加密，请让 `RCLONE_DEST` 指向 rclone crypt 远端。不要把备份文件、`.env`、`rclone.conf` 或密码提交到 Git。

## Plex 备份

### 默认执行

```bash
cd /root/linux-scripts
./plex-backup.sh
```

默认会：

1. 检查并锁定 `/run/plex-maintenance.lock`。
2. 如果 Plex 正在运行，则停止服务。
3. 将 Plex 应用数据打包到 `/var/backups/plex`。
4. 如果 Plex 原来正在运行，则重新启动服务。
5. 验证压缩包并生成相邻的 `.sha256` 文件。
6. 将校验文件和压缩包上传到 `NAtomJZXTR:`。

文件名格式：

```text
plex-YYYYMMDD-HHMMSS-PID.tar.gz
plex-YYYYMMDD-HHMMSS-PID.tar.gz.sha256
```

脚本备份 Plex 的配置、资料库数据库和元数据。它不会自动备份存放在其他目录中的电影、电视剧、音乐等媒体文件。默认排除可重建的 `Cache/`。

### 常用选项

```bash
# 只备份到本地，不上传
RCLONE_DEST='' ./plex-backup.sh

# 上传到远端的 plex-backups 目录
RCLONE_DEST='NAtomJZXTR:plex-backups' ./plex-backup.sh

# 同时备份 Cache
INCLUDE_CACHE=1 ./plex-backup.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PLEX_SERVICE` | `plexmediaserver` | systemd 服务名 |
| `PLEX_DATA_DIR` | `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server` | Plex 应用数据目录 |
| `BACKUP_DIR` | `/var/backups/plex` | 本地备份目录，不能位于 Plex 数据目录内 |
| `INCLUDE_CACHE` | `0` | 设为 `1` 时包含 `Cache/` |
| `RCLONE_DEST` | `NAtomJZXTR:` | 远端路径；空值表示禁用上传 |
| `RCLONE_CONFIG` | 空 | 可选的 `rclone.conf` 路径 |
| `LOCK_FILE` | `/run/plex-maintenance.lock` | Plex 备份和恢复共用的锁 |
| `PLEX_USER` | `plex` | 仅恢复脚本使用；还原后的文件所有者 |
| `PLEX_GROUP` | `plex` | 仅恢复脚本使用；还原后的文件所属组 |

Plex 脚本不会自动删除本地或远端的旧备份，请按自己的存储空间另行管理。

## Plex 恢复

新机器应先安装 Plex Media Server，使 systemd 服务、`plex` 用户和目标数据目录的父目录已经存在。建议安装与旧机器相同或兼容的 Plex 版本。

把压缩包及其 `.sha256` 文件放到 Plex 数据目录之外，然后执行：

```bash
./plex-restore.sh /root/plex-20260912-143458-982378.tar.gz
```

恢复脚本会停止 Plex、检查压缩包结构和关键数据库文件、恢复所有权，然后把原数据目录保留为：

```text
/var/lib/plexmediaserver/Library/Application Support/Plex Media Server.before-restore-时间戳-PID
```

如果相邻的 `.sha256` 文件存在，脚本会先校验它；缺少校验文件时会提示并继续检查 gzip 和 tar。只应恢复由本仓库备份脚本生成且来源可信的归档。

自定义 `PLEX_DATA_DIR` 时，其 basename 必须与归档的唯一顶层目录名一致，否则恢复脚本会拒绝该归档。

**恢复成功后 Plex 不会自动启动。** 检查输出和保留目录后，再手动启动：

```bash
systemctl start plexmediaserver
systemctl status plexmediaserver --no-pager
```

确认资料库正常前，请保留原压缩包、`.sha256` 和 `.before-restore-*` 目录。

## Vaultwarden 备份

默认目录结构应类似：

```text
/root/vaultwarden/
├── compose.yml          # 文件名也可以是其他标准 Compose 文件名
├── .env
└── data/
    └── db.sqlite3
```

容器的 `/data` 以及 `/data/*` 挂载必须是 bind mount，且源路径都在 `VW_DIR` 内。Compose 文件和 `.env` 也应放在 `VW_DIR` 中，这样它们才能随整个部署目录一起进入归档。

### 默认执行

```bash
cd /root/linux-scripts
./vaultwarden-backup.sh
```

默认会：

1. 检查 `NAtomJZXTR:vaultwarden-backups` 是否可访问。
2. 如果 Vaultwarden 容器正在运行，则停止容器。
3. 如果系统安装了 `sqlite3`，对数据库执行 `PRAGMA quick_check`。
4. 将整个 `/root/vaultwarden` 打包到 `/root/backups/vaultwarden`。
5. 如果容器原来正在运行，则重新启动容器。
6. 验证归档，生成 `.sha256`，依次上传校验文件和归档。
7. 删除超过 90 天的匹配远端备份，以及超过 7 天的匹配本地备份。

文件名格式：

```text
vaultwarden-full-stopped-主机名-YYYYMMDD-HHMMSS-PID-RANDOM.tar.gz
vaultwarden-full-stopped-主机名-YYYYMMDD-HHMMSS-PID-RANDOM.tar.gz.sha256
```

### 常用选项

```bash
# 只备份到本地，不上传
RCLONE_DEST='' ./vaultwarden-backup.sh

# 使用其他部署目录和本地备份目录
VW_DIR='/srv/vaultwarden' \
BACKUP_DIR='/srv/backups/vaultwarden' \
./vaultwarden-backup.sh

# 修改保留天数
LOCAL_RETENTION_DAYS=14 \
REMOTE_RETENTION_DAYS=180 \
./vaultwarden-backup.sh
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CONTAINER_NAME` | `vaultwarden` | 当前容器名 |
| `VW_DIR` | `/root/vaultwarden` | 要备份的完整部署目录 |
| `BACKUP_DIR` | `/root/backups/vaultwarden` | 本地备份目录，不能位于 `VW_DIR` 内 |
| `RCLONE_DEST` | `NAtomJZXTR:vaultwarden-backups` | 远端路径；空值表示禁用上传 |
| `RCLONE_CONFIG` | 空 | 可选的 `rclone.conf` 路径 |
| `RCLONE_CONFIG_PASS` | 空，由环境继承 | rclone 配置已加密时提供密码 |
| `LOCAL_RETENTION_DAYS` | `7` | 本地保留天数，必须是正整数 |
| `REMOTE_RETENTION_DAYS` | `90` | 远端保留天数，必须是正整数 |
| `BACKUP_HOST` | 当前短主机名 | 写入文件名的主机标识 |
| `LOCK_FILE` | `/run/vaultwarden-backup.lock` | Vaultwarden 备份和恢复共用的锁 |

归档只包含 `VW_DIR`。它不包含 Docker 镜像、named volume、外部数据库、外部网络，以及 `VW_DIR` 外的其他 bind mount。新机器需要预先安装 Docker/Compose，并创建 Compose 所引用的外部资源。

## Vaultwarden 恢复

### 1. 下载归档和校验文件

以下示例使用本仓库前面生成的文件名：

```bash
mkdir -p /root/vaultwarden-backups

rclone copyto \
  'NAtomJZXTR:vaultwarden-backups/vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz' \
  '/root/vaultwarden-backups/vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz'

rclone copyto \
  'NAtomJZXTR:vaultwarden-backups/vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz.sha256' \
  '/root/vaultwarden-backups/vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz.sha256'
```

恢复脚本不会自行从 rclone 下载文件。归档和相邻的 `.sha256` 文件必须保存在 `VW_DIR` 外。

可以先手动复核：

```bash
cd /root/vaultwarden-backups
sha256sum -c vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz.sha256
```

### 2. 恢复并启动

新机器已经安装 Docker、Docker Compose、Python 3 和 `sqlite3` 后，执行：

```bash
cd /root/linux-scripts
./vaultwarden-restore.sh \
  /root/vaultwarden-backups/vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz
```

默认 `START_CONTAINER=1`。脚本会在启动前验证归档、SQLite 完整性、Compose 配置、`/data` 挂载和数据库实际路径；启动后等待健康检查通过。没有健康检查时，容器持续运行 5 秒即视为启动成功。

### 3. 只恢复，不启动

```bash
cd /root/linux-scripts
START_CONTAINER=0 ./vaultwarden-restore.sh \
  /root/vaultwarden-backups/vaultwarden-full-stopped-ns562934-20260912-161147-991266-16062.tar.gz
```

这种模式仍会创建容器并完成挂载与配置检查，但让容器保持停止。确认后可在部署目录中手动启动对应 Compose 服务。

### 恢复选项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CONTAINER_NAME` | `vaultwarden` | 用于识别潜在同名容器 |
| `VW_DIR` | `/root/vaultwarden` | 恢复目标；归档顶层目录名必须等于其 basename |
| `COMPOSE_SERVICE` | 自动识别 | 无法唯一识别服务时显式指定 |
| `COMPOSE_FILE_NAME` | 自动识别 | 使用非标准文件名或存在多个主文件时显式指定 |
| `START_CONTAINER` | `1` | `0` 表示验证完成后保持停止 |
| `STARTUP_TIMEOUT` | `120` | 等待容器健康的秒数 |
| `DATA_DIR_REL` | 自动识别 | 多个 `db.sqlite3` 存在时，指定挂载到 `/data` 的相对目录 |
| `SKIP_SQLITE_CHECK` | `0` | `1` 跳过完整数据库检查，仅用于明确了解风险的情况 |
| `ALLOW_MISSING_CHECKSUM` | `0` | `1` 允许可信旧归档缺少 `.sha256` |
| `LOCK_FILE` | `/run/vaultwarden-backup.lock` | Vaultwarden 备份和恢复共用的锁 |

恢复时只自动识别以下主 Compose 文件：

```text
compose.yaml
compose.yml
docker-compose.yaml
docker-compose.yml
```

如果目录中存在多个主文件，请设置 `COMPOSE_FILE_NAME`。标准 override 文件会被拒绝，需要先合并到主 Compose 文件。若新机器上没有旧的 `VW_DIR`，归档本身必须包含可用的 Compose 文件；所需 `.env` 也应包含在归档内。

恢复前的目录会保留为 `<VW_DIR>.before-restore-*`。创建新容器后发生错误时，脚本会在能够确认容器安全停止的情况下自动回滚目录，并把失败的新数据保留为 `<VW_DIR>.failed-restore-*`。确认新实例正常前，不要删除这些目录。

## 定时备份

只把备份脚本加入 root 的 crontab，不要定时执行恢复脚本：

```bash
crontab -e
```

示例：

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RCLONE_CONFIG=/root/.config/rclone/rclone.conf

15 3 * * * /root/linux-scripts/plex-backup.sh >> /var/log/plex-backup.log 2>&1
45 3 * * * /root/linux-scripts/vaultwarden-backup.sh >> /var/log/vaultwarden-backup.log 2>&1
```

备份会造成短暂停机，请安排在低峰期。如果 `rclone.conf` 已加密，应通过受保护的环境提供 `RCLONE_CONFIG_PASS`，不要把密码写进仓库。

## 常见问题

### 提示另一个任务正在运行

Plex 的两个脚本共用 `/run/plex-maintenance.lock`，Vaultwarden 的两个脚本共用 `/run/vaultwarden-backup.lock`。先确认没有备份或恢复正在执行，再检查是否有异常退出后残留的进程。

### Vaultwarden 提示缺少校验文件

从远端把对应的 `.tar.gz.sha256` 一起下载。只有来源可信且确定是旧格式备份时，才使用：

```bash
ALLOW_MISSING_CHECKSUM=1 ./vaultwarden-restore.sh /path/to/backup.tar.gz
```

### Vaultwarden 找到多个数据库

显式指定实际挂载到容器 `/data` 的目录。例如数据库是归档内 `vaultwarden/data/db.sqlite3`：

```bash
DATA_DIR_REL='data' ./vaultwarden-restore.sh /path/to/backup.tar.gz
```

### rclone 上传失败

已成功生成的本地归档和校验文件会保留。修复远端配置后可手动上传，或重新运行备份。可先检查：

```bash
rclone config file
rclone lsd 'NAtomJZXTR:'
```
