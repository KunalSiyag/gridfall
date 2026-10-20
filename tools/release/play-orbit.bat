@echo off
rem Start GridFall in the orbit city-builder view instead of on foot.
set GRIDFALL_VIEW=orbit
start "" "%~dp0gridfall.exe" %*
