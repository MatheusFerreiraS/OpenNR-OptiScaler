@echo off
rem junctions.cmd on|off: the submodules under external\ as junctions to wt-upstream-merge's checkout (same commits),
rem for a build in this worktree. Run "off" before any git command.
cd /d "%~dp0..\.."
for %%n in (FidelityFX-SDK FidelityFX-SDK-v2 magic_enum nvapi simpleini spdlog unordered_dense vulkan xess) do (
  if exist "external\%%n" rmdir "external\%%n"
  if /i "%1"=="on" (mklink /J "external\%%n" "E:\Projetos\opti_rr_dlss5\wt-upstream-merge\external\%%n" >nul) else (mkdir "external\%%n")
)
