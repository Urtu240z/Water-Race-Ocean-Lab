@echo off
rem Compila el benchmark C++ independiente del core (sin godot-cpp).
rem Alineado con build_windows_release.bat: VS 2019/2022 o entorno ya cargado.
setlocal
set "VCDIR="
if defined VSINSTALLDIR set "VCDIR=%VSINSTALLDIR%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" (
  echo [ERROR] vcvars64.bat no encontrado.
  exit /b 1
)
call "%VCDIR%" >nul
cl /nologo /O2 /std:c++17 /EHsc /W3 bench\bench_main.cpp src\ocean_query_core.cpp /Fe:bin\bench_main.exe
endlocal
