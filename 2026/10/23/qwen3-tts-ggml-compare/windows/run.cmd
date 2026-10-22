@echo off
rem Run a lab command on Windows with the CUDA Toolkit's DLLs on PATH (a new ssh session does not see the installer's PATH).
set PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4\bin;C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4\bin\x64;%PATH%
uv run --project windows %*
