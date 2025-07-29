@echo off
echo Building trading-odin
odin build src -out:trading.exe -debug -extra-linker-flags:"/ignore:4099"
pause