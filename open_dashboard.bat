@echo off
title Open AEROSYS Telemetry HUD
echo Detecting local laptop identity...
python -c "import sys; sys.path.insert(0, '.'); from agent.config import open_dashboard_in_browser; open_dashboard_in_browser()"
if %errorlevel% neq 0 (
    echo Opening dashboard fallback...
    start "" "%~dp0dashboard\index.html"
)
