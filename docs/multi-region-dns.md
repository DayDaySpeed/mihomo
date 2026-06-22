# 多区域出口与 DNS 对齐架构

本文档说明如何让 **DNS 查询出口 IP** 与 **代理出口 IP** 在区域上保持一致。

---

## 问题背景

泄漏检测关注的是：**发起 DNS 查询时使用的公网源 IP**（DoH 连接从哪条链出去）。

若 DNS 从美国住宅链出去、网页却从德国链出去，任意检测站都会报不一致——与访问哪个网站无关。

---

## 核心机制

```
  DNS 查询
     │
     ├─ geosite:cn,private ──→ 国内 DoH #DIRECT
     │
     ├─ rule-set:PROXY-JP ──→ #CHAIN-PROXY-JP（rule-set 有域名时）
     │
     ├─ rule-set:PROXY-DE ──→ #CHAIN-PROXY-DE（同上）
     │
     ├─ rule-set:AI/Claude/… ──→ #CHAIN-PROXY-US（AI 流量 rules 固定美国）
     │
     └─ 其余境外域名 ──→ #DNS-REGION（面板手动选择）
```

### 三层优先级

| 优先级 | 机制 | 适用场景 |
|--------|------|----------|
| 1 | `geosite:cn,private` | 大陆 / 局域网，国内 DoH 直连 |
| 2 | `rule-set:PROXY-JP/DE` | 必须用非默认区域的特定域名（rule-set 可留空） |
| 3 | `rule-set:Claude,Chatgpt,…` | AI 固定美国（与 traffic rules 一致） |
| 4 | **`DNS-REGION`** | 所有其他境外域名 |

---

## DNS-REGION：切换出口时必须同步

Mihomo **无法**让 DNS 自动跟随 `FINAL` 里你手动选的节点。因此增加面板策略组 **`DNS-REGION`**：

```yaml
- name: DNS-REGION
  type: select
  proxies: [CHAIN-PROXY-US, CHAIN-PROXY-JP, CHAIN-PROXY-DE]
```

默认 `nameserver` / `fallback` 使用 `#DNS-REGION`，不再写死美国。

**使用规则**：你在 `FINAL`（或其它策略组）选用哪条区域住宅链，就把 **`DNS-REGION` 切成同一个**：

| 流量出口 | DNS-REGION 应设为 |
|----------|-------------------|
| `CHAIN-PROXY-US` | `CHAIN-PROXY-US` |
| `CHAIN-PROXY-JP` | `CHAIN-PROXY-JP` |
| `CHAIN-PROXY-DE` | `CHAIN-PROXY-DE` |

示例：用德国节点浏览普通境外站 → `FINAL` 选 `CHAIN-PROXY-DE`，同时 `DNS-REGION` 选 `CHAIN-PROXY-DE`。

若 `FINAL` 选德国、`DNS-REGION` 仍是美国 → **会不一致**，这是预期行为，需手动对齐。

AI 域名（ChatGPT 等）由 rules 固定走 `CHAIN-PROXY-US`，DNS policy 也固定 `#CHAIN-PROXY-US`，**不受 `DNS-REGION` 影响**。

---

## 非默认区域 rule-set（PROXY-JP / PROXY-DE）

默认区域由 **`DNS-REGION`** 控制。只有业务上**必须**某区域、且希望**即使用户切了 DNS-REGION 也不受影响**的域名，才写入 `ruleset/PROXY-JP.yml` 或 `PROXY-DE.yml`（流量 rules 与 nameserver-policy 共用）。留空 `payload: []` 表示暂未启用。

---

## 设计原则

1. **不逐站列举**：普通境外站靠 `DNS-REGION` 统一覆盖。
2. **手动同步**：切换 `FINAL` 区域链时，同步改 `DNS-REGION`（Mihomo 无自动联动）。
3. **AI 例外**：AI rules 与 DNS policy 均固定美国。
4. **国内分离**：`geosite:cn,private` 排在 policy 最前。
5. **不用 `respect-rules` 替代 policy**：无 `#` 后缀时 DoH 按 DoH 服务器域名选路。

---

## 配置组件

### 区域链式代理组

| 组名 | 角色 |
|------|------|
| `JP` | 日本 VLESS 订阅（Statry 等） |
| `CHAIN-PROXY-US/JP/DE` | 各区域出口链（JP 当前即 `JP` 订阅；可扩展住宅 SOCKS） |
| `DNS-REGION` | 面板可选，控制默认境外 DNS 出口 |

### 新增区域 Checklist

| 步骤 | 操作 |
|------|------|
| 1 | `secrets.yaml` 添加 `HOME-SOCKS5-{REGION}` |
| 2 | 添加 `CHAIN-PROXY-{REGION}` |
| 3 | 将 `CHAIN-PROXY-{REGION}` 加入 `DNS-REGION` 的 `proxies` 列表 |
| 4 | （可选）新建 `PROXY-{REGION}.yml` 强制特定域名走该区域 |

---

## 边界情况

### FINAL 选 SSRDOG / US（机房订阅）

`DNS-REGION` 不含 SSRDOG，仅 `CHAIN-PROXY-*` / `US` / `JP`。若 `FINAL` 选 SSRDOG，DNS 仍从 `DNS-REGION` 出去 → 可能不一致；敏感场景 `FINAL` 与 `DNS-REGION` 选同一区域链。

### 浏览器 Secure DNS

Chrome / Firefox 内置 DoH 会绕过 Mihomo，应关闭。

---

## 验证

1. 面板：`FINAL` 与 `DNS-REGION` 设为同一区域链。
2. 查看该链出口 IP。
3. 访问任意境外站 + DNS 泄漏检测页，确认 DNS 源 IP 与步骤 2 同区域。

---

## 相关文件

| 路径 | 说明 |
|------|------|
| `ssrdog.src.yaml` | `DNS-REGION`、nameserver-policy、默认 nameserver |
| `ruleset/PROXY-JP.yml` / `PROXY-DE.yml` | 可选的区域强制列表 |
| `secrets.yaml.example` | 各区域住宅 SOCKS 模板 |
