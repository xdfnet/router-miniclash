# 新增机场

机场以配置文件形式存放在 `airports/`，每机场一个 `<名字>.conf`。`airport-switch.sh` 读取这些文件，无需改动脚本本身。

## 1. 创建配置文件

在 `airports/` 下新建 `<名字>.conf`，文件名即切换时的机场名（小写、英文、无空格）。例如 `airports/backup.conf`：

```bash
# 机场备注（仅展示，可选）
URL="https://机场域名/订阅路径"        # 必填：订阅地址
NODES="默认节点,备用1,备用2,备用3"     # 必填：候选节点（逗号分隔，第 1 个为默认）
NOTE="机场补充说明"                   # 选填：套餐/到期/已知问题等
```

字段约束（脚本硬性要求）：

- `URL` 必填，缺失则报错退出
- `NODES` 必填，第 1 个为 fallback 默认节点（可达即锁定），其余为 url-test 备选
- 节点名含空格 / 反斜杠时直接写在引号内即可（脚本用单引号包 UCI 值，无需转义）

模板可直接复制 `airports/boostnet.conf`。

## 2. 切换

```bash
./scripts/airport-switch.sh backup         # 切到 backup 机场
./scripts/airport-switch.sh backup mt7981  # 切到 backup，路由器别名 mt7981
./scripts/airport-switch.sh                # 不带参数：列出所有可用机场
```

切换动作（脚本自动完成）：

1. 写 `URL` / `NODES` 到路由器 UCI
2. `force_update=1` 强制重拉订阅
3. `restart` 重启代理
4. 恢复 `force_update=0`
5. 实测 `github.com` 验证外网

## 3. 验证

切换后查看：

```bash
ssh luyou 'uci get miniclash.core.url'       # 当前订阅
ssh luyou 'uci get miniclash.core.nodes'     # 当前候选
ssh luyou 'uci get miniclash.core.node'      # 当前实际节点（watchdog 上报）
ssh luyou '/etc/init.d/miniclash status'     # 运行状态
```

外网连通（Mac 上）：

```bash
curl -s -o /dev/null -w "github → HTTP %{http_code} (%{time_total}s)\n" --max-time 15 https://github.com
```

## 4. 注意事项

- **节点名必须与订阅 YAML 里 `proxies:` 段完全一致**（含空格、大小写）。脚本只把名字传给 mihomo，不做翻译，名字错会变成 `mihomo: not found`。
- **缩进**：订阅 YAML 缩进由订阅源决定（4 空格或 2 空格），节点名本身不受影响。
- **GMS / 苹果 / 微软域名强制走代理**：init.d 已在 rules 最前注入，勿在订阅规则里再次改 DIRECT（参见 README「内核功能怎么用」）。
- **TLS 指纹**：gen_config 已对无指纹 flow 节点统一注入 firefox，无需手动配置。
