@echo off
rem ============================================================================
rem  build_windows_release.bat - Compila la GDExtension OceanQuery (Fase 2C)
rem  OFF-LINE (sin internet, sin pip): usa el SCons 4.11.0 extraido en
rem  native\deps\scons_site y el godot-cpp offline en native\godot-cpp.
rem
rem  Requisitos:
rem   - Python 3 (en PATH) para ejecutar SCons:  python -m SCons
rem   - MSVC Build Tools (vcvars64.bat). Se busca en las rutas tipicas de
rem     VS 2019/2022; si no se encuentra, usa VSINSTALLDIR ya cargado.
rem   - godot-cpp offline en native\godot-cpp (NO se descarga nada).
rem
rem  Salida: native\ocean_query\bin\water_race_ocean_query.windows.template_release.x86_64.dll
rem          + descriptor activo water_race_ocean_query.gdextension (solo si compila).
rem  Uso:   native\ocean_query\build_windows_release.bat
rem ============================================================================
setlocal

set "ROOT=%~dp0"

rem --- 1) SCons offline --------------------------------------------------------
set "SCONS_SITE=%ROOT%..\deps\scons_site"
if not exist "%SCONS_SITE%\SCons\__init__.py" (
    echo [ERROR] No se encuentra SCons offline en %SCONS_SITE%
    echo         Extrae scons-4.11.0-py3-none-any.whl ahi con: python -m zipfile -e
    exit /b 1
)
set "PYTHONPATH=%SCONS_SITE%"

rem --- 2) Entorno MSVC ---------------------------------------------------------
set "VCDIR="
if defined VSINSTALLDIR set "VCDIR=%VSINSTALLDIR%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" set "VCDIR=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCDIR%" (
    echo [ERROR] vcvars64.bat no encontrado. Ejecuta el script desde un Developer Command Prompt
    echo         o define VSINSTALLDIR.
    exit /b 1
)
call "%VCDIR%" >nul

rem --- 3) Compilar -------------------------------------------------------------
cd /d "%ROOT%"
echo [BUILD] Compilando OceanQuery (template_release) con SCons offline...
python -m SCons -Q platform=windows target=template_release
if errorlevel 1 (
    echo [ERROR] El build fallo. No se actualiza el descriptor activo.
    exit /b 1
)

echo.
echo [OK] DLL generada:
dir /b "bin\water_race_ocean_query.windows.template_release.x86_64.dll" 2>nul
echo [OK] Descriptor activo (regenerado solo si compilo):
dir /b "water_race_ocean_query.gdextension" 2>nul
endlocal
