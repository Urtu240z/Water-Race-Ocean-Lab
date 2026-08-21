@echo off
rem Compila el benchmark PATCH standalone (Fase 2C.1A): core DIRECT + PatchCore.
rem Requiere MSVC Build Tools (vcvars64.bat).
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /O2 /std:c++17 /EHsc /W3 bench\bench_patch_main.cpp src\ocean_query_core.cpp src\ocean_query_patch_core.cpp /Fe:bin\bench_patch_main.exe
