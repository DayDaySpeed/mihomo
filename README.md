# Mihomo 配置说明 · Mihomo Configuration Guide

本文档描述本仓库中 **Mihomo（Clash Meta）** 主配置 `ssrdog.yaml`、规则集与部署脚本的设计与用法。

---

## 目录 · Table of contents


| 中文                   | English                                                                   |
| -------------------- | ------------------------------------------------------------------------- |
| [一、概述](#一概述)         | [1. Overview](#1-overview-en)                                             |
| [二、目录结构](#二目录结构)     | [2. Repository layout](#2-repository-layout-en)                           |
| [三、主配置要点](#三主配置要点)   | [3. Main config highlights](#3-main-config-highlights-en)                 |
| [四、代理与策略组](#四代理与策略组) | [4. Proxies and policy groups](#4-proxies-and-policy-groups-en)           |
| [五、规则与规则集](#五规则与规则集) | [5. Rules and rule providers](#5-rules-and-rule-providers-en)             |
| [六、部署与重载](#六部署与重载)   | [6. Deployment and reload](#6-deployment-and-reload-en)                   |
| [七、运维与排错](#七运维与排错)   | [7. Operations and troubleshooting](#7-operations-and-troubleshooting-en) |


---

## 一、概述

本配置用于在 **Linux** 上以 **TUN 模式**运行 Mihomo：`ssrdog.src.yaml` 为可提交的模板，部署时与 `secrets.yaml` 合并为运行时配置；节点来自两个 **proxy-provider**（SSRDOG 订阅与本地 MYPROXY 订阅）；部分敏感流量走 **住宅 SOCKS5 链式代理**（美国 / 德国出口，分别经 MYPROXY 或 SSRDOG 作为第一层）。

设计目标包括：

- **分流**：国内大量域名走直连（`ChinaMax`、`DIRECT` 规则集）；AI / Google 系等走美国住宅链；哔哩哔哩 / YouTube 可选手动策略；其余走 `FINAL`。
- **DNS**：Fake-IP + `respect-rules`，并对订阅域名使用国内 DNS 解析（`nameserver-policy`）。
- **嗅探**：对 TLS/HTTP 端口嗅探，便于日志与策略基于域名。

---

## 二、目录结构


| 路径                                              | 说明                               |
| ----------------------------------------------- | -------------------------------- |
| `ssrdog.src.yaml`                               | 主配置模板（可公开提交，不含密钥）                 |
| `ssrdog.yaml`                                   | 合并后的本地配置（由部署脚本生成，**勿提交**）       |
| `secrets.yaml.example`                          | 敏感项模板；复制为 `secrets.yaml` 后填入真实值   |
| `secrets.yaml`                                  | 本地密钥（**勿提交**，已在 `.gitignore`）       |
| `merge_config.py`                               | 合并 `ssrdog.src.yaml` + `secrets.yaml` |
| `ruleset/*.yml`                                 | Classical 规则集（文件型 rule-provider） |
| `providers/ssrdog.yaml` / `providers/myai.yaml` | 由 Mihomo 从订阅拉取后写入（路径在配置中定义）      |
| `yaml.sh`                                       | 将配置与规则集同步到系统目录并重启服务              |
| `backup_ssrdog.yaml`                            | 脚本生成的备份（若存在）                     |


**注意**：配置里 `rule-providers` 使用相对路径 `./ruleset/...`。Mihomo 工作目录需使该路径指向实际规则目录（本仓库通过 `yaml.sh` 复制到 `/var/lib/mihomo/ruleset/`）。

---

## 三、主配置要点

### 3.1 控制面板与入口

- `**external-controller`**：`0.0.0.0:9090` — REST API / 面板。
- `**secret**`：API 鉴权，在 `secrets.yaml` 中配置（请自行保管，文档不展开）。
- `**external-ui**`：Web UI 静态资源路径（示例为 `/var/lib/mihomo/ui`，需与安装环境一致）。
- `**mixed-port**`：`7890` — 混合端口（HTTP/SOCKS）。
- `**allow-lan` / `bind-address**`：允许局域网访问时需理解安全风险。

### 3.2 TUN

- 启用 `**tun**`，`stack: system`，`auto-route`、`strict-route`、`force-dns-mapping` 等与透明代理常见组合一致。
- `**mtu: 1400**`：可按链路微调。

### 3.3 DNS

- `**enhanced-mode: fake-ip**`，`fake-ip-range: 198.18.0.1/16`。
- `**respect-rules: true**`：解析行为随路由规则，便于分流一致。
- `**nameserver-policy**`：对订阅相关域名指定国内 DNS（域名写在 `secrets.yaml`），避免解析异常。
- `**listen: 0.0.0.0:1053**`：DNS 监听地址与端口。

### 3.4 Sniffer

- 对 **443、8443**（TLS）及 **80、8080–8880**（HTTP）嗅探；`**override-destination: true`** 时以嗅探结果参与规则匹配（行为依内核版本与文档为准）。

### 3.5 其他

- `**mode: rule**`：规则模式。
- `**ipv6: false**`：全局关闭 IPv6（可按需打开）。
- `**profile.store-selected: true**`：记住用户在面板中选中的策略组节点。

---

## 四、代理与策略组

### 4.1 Proxy providers


| 名称            | 作用                                            |
| ------------- | --------------------------------------------- |
| `**ssrdog**`  | HTTP 订阅，拉取 SSRDOG 节点；健康检查 `generate_204`      |
| `**myproxy**` | HTTP 订阅（示例 URL 指向本机 `127.0.0.1:3001`，需自备订阅服务） |


更新周期、路径 `./providers/*.yaml` 与 `User-Agent` 等在 `ssrdog.yaml` 内可改；**订阅 URL** 在 `secrets.yaml`。

### 4.2 策略组（节选）


| 名称                   | 类型       | 说明                                                                                            |
| -------------------- | -------- | --------------------------------------------------------------------------------------------- |
| `**SSRDOG**`         | url-test | 使用 `ssrdog` provider 中节点，自动测速选优                                                               |
| `**MYPROXY**`        | url-test | 使用 `myproxy` provider 中节点，自动测速选优                                                              |
| `**BiliBili**`       | select   | 哔哩哔哩：`DIRECT` / `SSRDOG`                                                                      |
| `**YouTube**`        | select   | YouTube：`MYPROXY` / `SSRDOG`                                                                  |
| `**CHAIN-PROXY-US**` | url-test | 美国住宅 SOCKS5 二选一：`HOME-SOCKS5-US`（经 MYPROXY）与 `HOME-SOCKS5-SSRDOG-US`（经 SSRDOG）；`hidden: true` |
| `**CHAIN-PROXY-DE**` | url-test | 德国住宅 SOCKS5 二选一；`hidden: true`                                                                |
| `**CHAIN-PROXY**`    | select   | 四条住宅链手动选择（美×2 + 德×2）                                                                          |
| `**FINAL**`          | select   | 默认兜底：`MYPROXY`、`SSRDOG`、`CHAIN-PROXY-US`、`CHAIN-PROXY-DE`、`DIRECT`                            |


### 4.3 链式代理（住宅 SOCKS5）

每条 `**HOME-SOCKS5-***` 为 **SOCKS5**，通过 `**dialer-proxy`** 先连入 `MYPROXY` 或 `SSRDOG`，再连住宅 IP，形成 **代理链**。节点与认证信息在 `secrets.yaml` 维护。

---

## 五、规则与规则集

### 5.1 规则顺序（自上而下，先匹配先生效）


| 规则                                           | 策略             | 说明                                      |
| -------------------------------------------- | -------------- | --------------------------------------- |
| `DOMAIN,dog.ssrdog.com`                      | SSRDOG         | 订阅相关域名                                  |
| `DOMAIN-SUFFIX,<订阅域名>`（见 `secrets.yaml`） | DIRECT         | 订阅下载域名直连                                |
| `RULE-SET,REJECT`                            | REJECT         | 拦截列表                                    |
| `RULE-SET,DNS_DIRECT`                        | DIRECT         | DNS 直连列表                                |
| `RULE-SET,DNS_PROXY`                         | CHAIN-PROXY    | DNS 需代理列表（当前指向四链 `select` 组）            |
| `RULE-SET,Claude/Chatgpt/Gemini/Google/Grok` | CHAIN-PROXY-US | AI / Google 系等走美国住宅链（自动测速二选一）           |
| `DOMAIN-SUFFIX,bilibili.com` 等               | BiliBili       | 哔哩哔哩可选手动选 DIRECT 或 SSRDOG（优先于 ChinaMax） |
| `RULE-SET,YouTube`                           | YouTube        | 由 `YouTube` 策略组再选 MYPROXY 或 SSRDOG      |
| `RULE-SET,DIRECT`                            | DIRECT         | 自定义直连（含 `GEOIP,CN` 等，以 `DIRECT.yml` 为准） |
| `RULE-SET,ChinaMax`                          | DIRECT         | 大陆域名 / IP 大表                            |
| `MATCH`                                      | FINAL          | 其余走 `FINAL`                             |


若需 **DNS 也走美国住宅链**，可将 `DNS_PROXY` 的策略从 `CHAIN-PROXY` 改为 `CHAIN-PROXY-US`（或你期望的组），与 AI 规则保持一致。

### 5.2 规则集文件（`ruleset/`）


| 文件                                                                      | 用途                                                    |
| ----------------------------------------------------------------------- | ----------------------------------------------------- |
| `DIRECT.yml`                                                            | 教育网关键词、局域网、自定义直连等                                     |
| `REJECT.yml`                                                            | 广告或屏蔽                                                 |
| `DNS_DIRECT.yml` / `DNS_PROXY.yml`                                      | DNS 分流列表                                              |
| `Chatgpt.yml` / `Claude.yml` / `Gemini.yml` / `Google.yml` / `Grok.yml` | 各服务域名                                                 |
| `YouTube.yml`                                                           | YouTube 相关域名 / 关键字 / IP（含 `DOMAIN-KEYWORD,youtube` 等） |
| `ChinaMax.yml`                                                          | 大陆分流大表（体积较大，首次部署由 `yaml.sh` 自动拉取；设 `UPDATE_CHINAMAX=1` 可强制更新） |


---

## 六、部署与重载

首次部署或新环境：

```bash
cp secrets.yaml.example secrets.yaml
# 编辑 secrets.yaml 填入 secret、订阅 URL、住宅 SOCKS 等
pip install -r requirements.txt   # 或依赖系统 python3-yaml / PyYAML
```

`yaml.sh` 典型流程：

1. 若本地缺少 `ruleset/ChinaMax.yml`，从 [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) 拉取（`UPDATE_CHINAMAX=1` 可强制更新）
2. 用 `merge_config.py` 合并 `ssrdog.src.yaml` 与 `secrets.yaml`
3. 备份当前 `/etc/mihomo/ssrdog.yaml` 到仓库内 `backup_ssrdog.yaml`（若存在）
4. 安装合并后的配置 → `/etc/mihomo/ssrdog.yaml`
5. 将 `ruleset/*.yml` 同步到 `/var/lib/mihomo/ruleset/`
6. 修正属主为 `mihomo` 用户
7. `systemctl restart mihomo`
8. 在仓库内写入 `ssrdog.yaml` 供本地查看（已 gitignore）

请在仓库根目录执行（需 sudo）：

```bash
bash yaml.sh
```

确保 Mihomo 服务使用的 `**-d`（工作目录）** 与规则路径一致（常见为 `/var/lib/mihomo`）。

---

## 七、运维与排错

- **配置校验**：在允许的路径下执行 `mihomo -t -f /path/to/ssrdog.yaml`；若报 `SAFE_PATHS` / `external-ui` 路径错误，需与本地安全策略或实际安装路径对齐。
- **连接日志中的 Rule**：`RuleSet` + 规则集名表示命中对应 provider；`Chains` 显示实际代理链。
- **Fake-IP**：源地址可能出现 `198.18.x.x`，属预期。
- **订阅与密钥**：更换 SSRDOG / 住宅 SOCKS 时改 `secrets.yaml` 中对应字段，并重新部署。

---

# English sections

## 1. Overview {#1-overview-en}

This setup runs **Mihomo** on **Linux** with **TUN** enabled. `ssrdog.src.yaml` is the public template; deployment merges it with `secrets.yaml` into the runtime config. Outbound nodes come from two **proxy providers** (SSRDOG subscription and a local MYPROXY subscription). Sensitive traffic can use **residential SOCKS5 chains** (US / DE exit), each chained through either **MYPROXY** or **SSRDOG** as the first hop.

Goals:

- **Routing**: large China domain lists go **DIRECT** (`ChinaMax`, `DIRECT`); AI / Google-related traffic uses the **US residential chain**; YouTube uses the `**YouTube`** selector; everything else hits `**MATCH` → `FINAL**`.
- **DNS**: Fake-IP with `**respect-rules`**, plus `**nameserver-policy**` for subscription hostnames.
- **Sniffer**: TLS/HTTP sniffing for better domain visibility in logs and rule matching.

---

## 2. Repository layout {#2-repository-layout-en}


| Path                                           | Purpose                                                        |
| ---------------------------------------------- | -------------------------------------------------------------- |
| `ssrdog.src.yaml`                              | Main configuration template (safe to publish)                |
| `ssrdog.yaml`                                  | Merged local config (generated by deploy script, gitignored) |
| `secrets.yaml.example`                         | Template for secrets; copy to `secrets.yaml` locally         |
| `secrets.yaml`                                 | Local secrets (**do not commit**, listed in `.gitignore`)    |
| `merge_config.py`                              | Merges `ssrdog.src.yaml` + `secrets.yaml`                    |
| `requirements.txt`                             | Python deps for `merge_config.py` (`PyYAML`)                 |
| `ruleset/*.yml`                                | Classical rule-set files                                     |
| `ruleset/ChinaMax.yml`                         | Large CN list; auto-fetched by `yaml.sh` if missing          |
| `providers/ssrdog.yaml`, `providers/myai.yaml` | Fetched and written by Mihomo (paths defined in config)        |
| `yaml.sh`                                      | Copies config + rules to system paths and restarts the service |


Rule providers reference `**./ruleset/...`**. The Mihomo working directory must resolve that path (this repo uses `yaml.sh` to mirror files under `/var/lib/mihomo/ruleset/`).

---

## 3. Main config highlights {#3-main-config-highlights-en}

- **API / UI**: `external-controller` on `9090`, `secret` for auth, `external-ui` path must exist on the target machine.
- **TUN**: system stack, auto routing, strict routing, forced DNS mapping; tune `mtu` if needed.
- **DNS**: fake-ip pool `198.18.0.0/16`, DoH upstreams, policy for specific subscription suffixes.
- **Sniffer**: TLS (443/8443) and HTTP (80/8080–8880); `override-destination` affects how domains are matched.
- **Mode**: `rule`; IPv6 disabled globally in this file unless you change it.

---

## 4. Proxies and policy groups {#4-proxies-and-policy-groups-en}

- `**SSRDOG` / `MYPROXY`**: `url-test` groups backed by `**proxy-providers**` with health checks to Cloudflare `generate_204`.
- `**CHAIN-PROXY-US` / `CHAIN-PROXY-DE**`: `url-test` over two SOCKS5 hops each (via `MYPROXY` vs `SSRDOG`); `**hidden: true**` hides them from some UIs but they remain usable in rules.
- `**CHAIN-PROXY**`: manual `select` across all four residential chains.
- `**FINAL**`: user-selectable fallback for `MATCH` traffic.

Residential SOCKS entries use `**dialer-proxy**` to build **proxy chains**. Keep credentials in `secrets.yaml` (gitignored).

---

## 5. Rules and rule providers {#5-rules-and-rule-providers-en}

Rules are evaluated **top to bottom**. Highlights:

- Subscription helper domains → `**SSRDOG`** or **DIRECT** as written.
- AI / Google rule-sets → `**CHAIN-PROXY-US`** (auto fastest chain).
- `**DNS_PROXY**` → `**CHAIN-PROXY**` in the current file (a **select** group with four chains). Change to `**CHAIN-PROXY-US`** if you want DNS proxy traffic aligned with the US-only chain.
- `**ChinaMax` / `DIRECT**` → **DIRECT** for CN-oriented lists.
- `**MATCH`** → `**FINAL**`.

Rule-set files live under `**ruleset/**`; `**YouTube.yml**` includes broad `**DOMAIN-KEYWORD,youtube**` coverage in addition to explicit domains.

---

## 6. Deployment and reload {#6-deployment-and-reload-en}

`yaml.sh`:

1. Fetches `ruleset/ChinaMax.yml` if missing (set `UPDATE_CHINAMAX=1` to refresh)
2. Merges `ssrdog.src.yaml` with `secrets.yaml` via `merge_config.py`
3. Backs up `/etc/mihomo/ssrdog.yaml`
4. Installs the merged config
5. Syncs `ruleset/*.yml` into `/var/lib/mihomo/ruleset/`
6. Fixes ownership for the `mihomo` user
7. Restarts **mihomo**
8. Writes `ssrdog.yaml` locally for inspection (gitignored)

First-time setup: `cp secrets.yaml.example secrets.yaml` and fill in your values.

Run from the repo root with appropriate privileges:

```bash
bash yaml.sh
```

---

## 7. Operations and troubleshooting {#7-operations-and-troubleshooting-en}

- Run `**mihomo -t**` with a config path allowed by your `**SAFE_PATHS**` (if enabled).
- `**RuleSet` / `Chains**` in the UI explain which rule matched and which outbound path was used.
- `**198.18.0.0/16**` sources are typical with fake-ip.
- Rotate subscriptions and SOCKS credentials in `**secrets.yaml**` only; avoid publishing secrets.

---

## 许可与致谢 · License and credits

- 规则集多来自社区项目（如规则文件头注释中的 **blackmatrix7** 等），使用前请遵守各自仓库许可。
- Rule-set files may credit third-party projects (see headers inside each `ruleset/*.yml`); respect their licenses when redistributing.

