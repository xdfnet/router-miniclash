#!/bin/bash
# 启动代理

ssh luyou '/etc/init.d/miniclash start && echo 代理已启动 || echo 启动失败'
