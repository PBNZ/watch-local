# Linux test environment for the watch-local suite -- DEV TOOLING ONLY.
# The plugin itself requires no Docker; this image gives a Windows build
# machine a real Linux target (pwsh + python3) for the pwsh-on-Linux leg
# of the test matrix, including genuine linux_x64 runtime provisioning.
#
# Build/run via tests/linux/run-linux-tests.ps1.

FROM mcr.microsoft.com/powershell:latest

# python3/pytest for the worker unit suite; tar + xz for the BtbN ffmpeg
# archive the runtime provisioner extracts; ca-certificates for downloads.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip ca-certificates tar xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Newer Ubuntu bases mark the system python "externally managed" (PEP 668);
# fall back to --break-system-packages there.
RUN python3 -m pip install --no-cache-dir pytest \
 || python3 -m pip install --no-cache-dir --break-system-packages pytest

# Pester pinned to the 5.x line: 6.0.0 currently fails to import on Linux
# pwsh ("Cannot bind parameter 'TypeConverter'"), and the suite targets the
# Pester 5 API.
RUN pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99 -Force -SkipPublisherCheck -Scope AllUsers"

# The Pester sandboxes build paths from these; _lib.ps1 itself uses the
# XDG fallback (~/.local/share) on Linux and ignores LOCALAPPDATA.
ENV TEMP=/tmp \
    LOCALAPPDATA=/tmp/localappdata

RUN mkdir -p /tmp/localappdata
