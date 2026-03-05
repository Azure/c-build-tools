@echo off
REM This script checks for vld.h anywhere and if found returns 1. 
REM Returns 2 when it errors. Returns 0 when it doesn't find vld.h in *.h, *.c, *.cpp and *.txt files
REM Exclusions should be passed as arguments in git pathspec format, e.g.:
REM   vld_check.bat ":(exclude)path/to/file.c" ":(exclude)deps/folder/"

setlocal enabledelayedexpansion

set "EXCLUSIONS="
:parse_args
if "%~1"=="" goto run_check
set "EXCLUSIONS=!EXCLUSIONS! %~1"
shift
goto parse_args

:run_check
git grep "vld.h" -- *.c *.h *.cpp *.txt %EXCLUSIONS%
if errorlevel 2 exit /b 2
if errorlevel 1 exit /b 0
if errorlevel 0 exit /b 1
