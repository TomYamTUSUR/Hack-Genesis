@echo off
cd /d "%~dp0"
bundle exec ruby bin\menu.rb %*
pause
