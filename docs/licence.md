# L1 离线授权

默认安装保持原有流程。启用 `--require-licence` 后，L1 在校验和写入工作区之前验证签名、机器码和到期时间。`--check` 与 `--require-licence` 可以合用。

```bash
bash distribution/l1/install.sh /path/to/workspace --require-licence --licence /path/to/licence.json
```

省略 `--licence` 时使用目标目录中的 `licence.json`。单独传 `--licence` 时仍执行默认安装。

## 发布者签发

1. 在仓库外生成 RSA-2048 密钥对。私钥权限为 `600`，已存在的私钥会使生成命令报错。将命令输出的公钥保存为 `distribution/l1/licence/public.pem`，替换占位内容。

   ```bash
   bash distribution/l1/licence/keygen.sh "$HOME/kualang-licence/private.pem" > /tmp/workbench-public.pem
   ```

2. 让使用者在目标机器运行 `python3 distribution/l1/licence/verify.py --print-machine-id`，并将结果发给发布者。macOS 使用 `IOPlatformUUID`，Linux 使用 `/etc/machine-id`。
3. 填写 `licensee`、`tier`、`machine_id`、`issued_at`、`expires_at`，全部使用 JSON 字符串。时间使用带时区的 ISO 8601 时间戳，例如 `2027-01-01T00:00:00Z`。将这五个字段以 Python `json.dumps(data, sort_keys=True, separators=(",", ":"))` 序列化为 UTF-8 字节，交给系统 `/usr/bin/openssl dgst -sha256 -sign <私钥路径>` 签名。将签名用标准 Base64 编码为 `sig`，随五个字段一并写入 `licence.json`。
4. 在目标机器用 `python3 distribution/l1/licence/verify.py --licence /path/to/licence.json` 离线验证，再启用安装闸。发布者将私钥留在仓库及发行包之外。

| 退出码 | 含义 |
|---|---|
| `0` | 校验成功 |
| `2` | 授权文件或公钥不可读（`E_LICENCE_FILE`） |
| `3` | 无法获取本机机器码（`E_LICENCE_MACHINE`） |
| `4` | 授权格式、RSA-2048 公钥或签名校验失败（`E_LICENCE_SIGNATURE`） |
| `5` | 授权绑定的机器码与本机不同（`E_LICENCE_MACHINE`） |
| `6` | 到期时间已到（`E_LICENCE_EXPIRED`） |

运行 `bash distribution/licence-selftest.sh` 可用临时密钥复核签名、篡改、错误机器、过期和默认安装。
