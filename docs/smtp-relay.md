# VPS 邮件中转（SMTP Relay）

在国内网络下，直连 `smtp.gmail.com:587/465` 常被干扰；机场代理与住宅 SOCKS 也普遍封锁 SMTP 端口。本方案在 **海外 VPS** 上运行 Postfix，由邮件客户端把发信流量提交到 VPS，再由 VPS 转发到 Gmail。

```
邮件客户端 ──587/STARTTLS──► VPS (Postfix) ──► smtp.gmail.com ──► 收件人
              ↑ 中继账号认证              ↑ Google 应用专用密码
```

**收件（IMAP）** 仍走 Gmail 官方服务器，只需改 **发信（SMTP）**。

---

## 前置条件

| 项 | 说明 |
|---|---|
| VPS | Ubuntu 24.04，有公网 IP，开放入站 **TCP 587**（云厂商安全组 + 本机 `ufw`） |
| Gmail | 已开启两步验证 |
| Google 应用专用密码 | [Google 账号 → 安全 → 应用专用密码](https://myaccount.google.com/apppasswords) 生成，供 VPS 连接 Gmail 使用 |
| 中继密码 | **自行设定**，供邮件客户端登录 VPS，与 Google 密码无关 |

---

## 初次安装

### 1. 上传脚本

在本机仓库根目录执行：

```bash
scp scripts/vps-smtp-relay.sh root@<VPS_IP>:/root/
```

### 2. 在 VPS 上安装

**环境变量必须写在同一行**（或先 `export`），否则子进程读不到：

```bash
RELAY_USER=relay \
RELAY_PASS='<你设的中继密码>' \
GMAIL_USER='you@gmail.com' \
GMAIL_APP_PASS='<Google应用专用密码>' \
bash /root/vps-smtp-relay.sh
```

脚本会：

- 安装 Postfix、`libsasl2-modules-db` 等依赖
- 创建自签 TLS 证书（客户端需接受）
- 写入 SASL 中继账号（realm = VPS 公网 IP）
- 配置 Gmail 出站：`relayhost = [smtp.gmail.com]:587`
- 监听 **587**（submission），`ufw` 放行该端口

### 3. VPS 上自测

```bash
apt-get install -y swaks

swaks --to you@gmail.com --from you@gmail.com \
  --server 127.0.0.1 --port 587 --tls \
  --auth LOGIN --auth-user relay --auth-password '<RELAY_PASS>' \
  --header 'Subject: relay test'
```

成功标志：

- `235 Authentication successful`
- `250 2.0.0 Ok: queued as ...`

---

## 邮件客户端配置

### 当前实例（本仓库 VPS）

发信（SMTP）填法：

| 项 | 值 |
|---|---|
| SMTP 服务器 | `38.207.189.240` |
| 端口 | `587` |
| 加密 | STARTTLS |
| 用户名 | `relay` |
| 密码 | `bwUMtSIMJOx3cGx5ufe1` |
| 发件人 | `us2jianging@gmail.com` |

自签证书需在客户端勾选「信任此证书」/「接受风险」。

### 发信（SMTP）— 通用说明

若使用其他 VPS 或自行修改过中继密码，将上表对应项替换为：

| 项 | 值 |
|---|---|
| SMTP 服务器 | VPS 公网 IP |
| 端口 | `587` |
| 加密 | **STARTTLS**（不要选 SSL/465） |
| 认证 | 开启 |
| 用户名 | `RELAY_USER`（默认 `relay`） |
| 密码 | 安装时设置的 `RELAY_PASS` |
| 发件人地址 | 你的 Gmail 地址 |

### 收件（IMAP）— 仍用 Gmail

| 项 | 值 |
|---|---|
| IMAP 服务器 | `imap.gmail.com` |
| 端口 | `993` |
| 加密 | SSL/TLS |
| 用户名 / 密码 | Gmail 地址 + 应用专用密码（或 OAuth，视客户端而定） |

### 常见客户端

**Thunderbird**：账户设置 → 服务器设置 / 发件服务器 → 按上表填写；SMTP 安全连接选「STARTTLS」。

**Apple Mail**：邮件 → 账户 → 发件服务器 → 自定义；勾选「使用 TLS/SSL」并选手动配置。

**注意**：SMTP **不要**再填 `smtp.gmail.com`，也**不要**让 SMTP 走系统代理；应直连 VPS IP。

---

## 两种密码的区别

| 变量 | 谁用 | 填在哪 |
|---|---|---|
| `RELAY_PASS` | 邮件客户端 → VPS | Thunderbird / Outlook 的 SMTP 密码 |
| `GMAIL_APP_PASS` | VPS → Gmail | 仅安装脚本时使用，写入 `/etc/postfix/sasl_passwd` |

```
客户端 --[RELAY_USER / RELAY_PASS]--> VPS --[GMAIL_USER / GMAIL_APP_PASS]--> Gmail
```

---

## 修改中继密码

在 VPS 上：

```bash
VPS_IP=$(hostname -I | awk '{print $1}')
echo '新密码' | saslpasswd2 -p -c -u "$VPS_IP" relay
chown postfix:postfix /etc/sasldb2
chmod 660 /etc/sasldb2
systemctl restart postfix
```

同步更新邮件客户端里的 SMTP 密码。

---

## 排错

### 535 Authentication failed（客户端登录 VPS 失败）

1. 确认 `sasldb` 有条目：`sasldblistusers2 -f /etc/sasldb2` 应显示 `relay@<VPS_IP>`
2. 确认已安装：`apt-get install -y libsasl2-modules-db`
3. 确认 `/etc/postfix/sasl/smtpd.conf` 存在且内容为 `auxprop` + `sasldb`
4. 确认 `master.cf` 里 submission 的 **chroot 为 `n`**（`chroot=y` 时读不到 `/etc/sasldb2`）：

   ```
   submission inet n       -       n       -       -       smtpd
   ```

5. 确认 realm：`postconf smtpd_sasl_local_domain` 应等于 VPS 公网 IP

### 本机连不上 VPS:587

- 云厂商控制台安全组放行 **TCP 587**
- VPS 上：`ufw status` 应含 `587/tcp ALLOW`
- 本机测试：`bash -c 'echo >/dev/tcp/<VPS_IP>/587'`

### 认证成功但邮件发不出去

- 查看队列：`mailq`
- 查看日志：`journalctl -u postfix -f` 或 `tail -f /var/log/mail.log`
- 检查 Gmail 应用专用密码是否有效、`/etc/postfix/sasl_passwd` 是否正确

### 重新跑安装脚本

可重复执行（会覆盖 SASL 用户与 Gmail 出站配置）：

```bash
RELAY_USER=relay RELAY_PASS='...' GMAIL_USER='...' GMAIL_APP_PASS='...' bash /root/vps-smtp-relay.sh
```

---

## 安全建议

- `RELAY_PASS` 使用强随机密码，不要与 Gmail 密码相同
- 不要将 `GMAIL_APP_PASS` 提交到 Git 或贴在公开场合；泄露后应在 Google 撤销并重新生成
- Postfix 仅允许 **SASL 认证用户**中继，未认证请求会被拒绝
- 若固定从家中 IP 发信，可在 `ufw` 将 587 限制为自家 IP（可选）

---

## 相关文件

| 路径 | 说明 |
|---|---|
| `scripts/vps-smtp-relay.sh` | VPS 一键安装脚本 |
| VPS `/etc/postfix/main.cf` | Postfix 主配置 |
| VPS `/etc/postfix/master.cf` | submission（587）服务定义 |
| VPS `/etc/postfix/sasl_passwd` | VPS → Gmail 凭证（权限 600） |
| VPS `/etc/sasldb2` | 客户端 → VPS 中继账号 |
