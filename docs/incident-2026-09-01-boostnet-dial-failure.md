# 事故报告：2026-09-01 BoostNet 恢复后全部节点拨号失败

## 现象

- 2026-08-31 BoostNet 机场停摆（服务端公告）。
- 2026-09-01 机场恢复，但路由器上 mihomo 对**全部节点**拨号失败，日志为 `i/o timeout`。
- 最初怀疑服务端故障（机场刚恢复），实际根因在本机链路。

## 根因

两个因素叠加，导致 TLS 握手包在 WAN 链路上丢失：

1. **ClientHello 超 MSS**：mihomo 默认 utls 指纹的 ClientHello 达 1510B，超过 TCP MSS（1452），需 IP 分片。
2. **GSO/TSO 大包被丢**：路由器 eth1 的 GSO/TSO 把隧道内 TLS record 合并成大包，中间设备（光猫）丢弃前段；对端 SACK 只确认尾部 → 握手永远无法完整 → `i/o timeout`。

机场正常时该链路问题被掩盖；停摆恢复后重新拨号才稳定暴露。

## 修复

1. **TLS 指纹注入**：gen_config 对 proxies 段无 `client-fingerprint` 的节点统一注入 `firefox`——指纹包小、单段不分片。
2. **关闭 WAN GSO/TSO**：start() 执行 `ethtool -K eth1 gso off tso off`；stop() 恢复默认。

## 验证

修复后全部节点拨号恢复，google / youtube / github 正常；大流量传输间歇失败问题同步消失。

## 教训

- 拨号全灭不等于服务端故障；先看握手包大小与网卡 offload 链路。
- 注入行 / 组结构变更时保持 YAML 缩进逐字节一致（见 [architecture.md](architecture.md)「缩进自适应」）。
