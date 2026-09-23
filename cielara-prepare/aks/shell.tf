# The module's CLI probes are bash scripts. On Windows, bash on PATH is usually
# System32\bash.exe, the WSL launcher, which cannot see the Windows aws, gcloud
# or az CLIs, so Windows runs them under Git Bash instead.
locals {
  is_windows = !startswith(abspath(path.root), "/")

  windows_git_bash = [
    for p in [
      "C:/Program Files/Git/bin/bash.exe",
      pathexpand("~/AppData/Local/Programs/Git/bin/bash.exe"),
    ] : p if fileexists(p)
  ]

  bash_missing = var.bash_path == null && local.is_windows && length(local.windows_git_bash) == 0
  bash         = var.bash_path != null ? var.bash_path : local.is_windows ? try(local.windows_git_bash[0], "bash") : "bash"

  bash_missing_error = "Git Bash not found. Install Git for Windows (https://git-scm.com/download/win), or set bash_path to its bin/bash.exe. The WSL bash in System32 cannot run this module's checks."
}
