# The destroy-time cleanup is a bash script. On Windows, bash on PATH is usually
# System32\bash.exe, the WSL launcher, which cannot see the Windows aws CLI, so
# Windows runs it under Git Bash instead. Without Git Bash the cleanup is
# skipped and destroy behaves as if it were not there.
locals {
  is_windows = !startswith(abspath(path.root), "/")

  windows_git_bash = [
    for p in [
      "C:/Program Files/Git/bin/bash.exe",
      pathexpand("~/AppData/Local/Programs/Git/bin/bash.exe"),
    ] : p if fileexists(p)
  ]

  bash = var.bash_path != null ? var.bash_path : local.is_windows ? try(local.windows_git_bash[0], "bash") : "bash"
}
