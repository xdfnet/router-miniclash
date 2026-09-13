#!/bin/bash
# 关闭代理

ssh luyou '/etc/init.d/miniclash stop && echo 代理已关闭 || echo 关闭失败'
