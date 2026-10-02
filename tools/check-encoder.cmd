@echo off
chcp 65001 >nul
title Sunshine 编码器检查（硬编 / 软编）
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-encoder.ps1" -NoPause %*
echo.
echo （按任意键关闭窗口）
pause >nul