@echo off
title PC Health Monitoring Agent
cd /d "%~dp0"
python -m agent.main
pause
