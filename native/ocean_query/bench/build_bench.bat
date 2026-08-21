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
rem Aislamiento también en standalone: sólo el objeto SIMD recibe /arch:AVX2.
cl /nologo /O2 /std:c++17 /EHsc /W3 /c src\ocean_query_core.cpp /Fo:bin\ocean_query_core_scalar.obj
if errorlevel 1 exit /b 1
cl /nologo /O2 /std:c++17 /EHsc /W3 /arch:AVX2 /c src\ocean_query_simd_avx2.cpp /Fo:bin\ocean_query_simd_avx2.obj
if errorlevel 1 exit /b 1
cl /nologo /O2 /std:c++17 /EHsc /W3 /c bench\bench_main.cpp /Fo:bin\bench_main.obj
if errorlevel 1 exit /b 1
link /nologo /out:bin\bench_main.exe bin\bench_main.obj bin\ocean_query_core_scalar.obj bin\ocean_query_simd_avx2.obj
endlocal
