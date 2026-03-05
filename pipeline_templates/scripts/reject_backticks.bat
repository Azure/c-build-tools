@echo off
REM This script checks for the regular expression "SRS.*\[.*`.*\]" in *.h, *.c and *.cpp files
REM This rejection is intended to guard requirements from being copy/pasted into code in their raw form.
REM Requirements should appear in the code/tests in their rendered form, which lacks backticks.
REM If regular expression is found then the script returns 1.
REM If the regular expression is not found it returns 0 (and so the gate passes).
REM Returns 2 when it errors.

git grep -E "SRS.*\[.*`.*\]" -- *.c *.h *.cpp
if errorlevel 2 exit /b 2
if errorlevel 1 exit /b 0
if errorlevel 0 exit /b 1
