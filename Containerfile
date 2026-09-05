# Self-contained image for running dvd-ripper.sh: the makemkv PPA and the
# DVD/Blu-ray ripping & transcoding toolchain, plus the script itself baked
# in as the entrypoint. Each dvd-ripper.sh command (rip/scan/encode) runs in
# its own short-lived container -- spawn, run, collect output, exit.
#
# Build:
#   podman build -t localhost/media-ripper:latest -f Containerfile .
#
# Run a command (from inside the movie/season folder, so relative paths like
# ./output line up):
#   podman run --rm -v "$PWD":/work -w /work --device=/dev/sr0 \
#       localhost/media-ripper:latest rip
#
#   podman run --rm -v "$PWD":/work -w /work \
#       localhost/media-ripper:latest scan --input ./output/title_t00.mkv
#
#   podman run --rm -v "$PWD":/work -w /work \
#       localhost/media-ripper:latest encode --name "Movie Title (Year)" \
#       --input ./output/title_t00.mkv --audio 1,2 --subtitle 1,11
#
# --device=/dev/sr0 is only needed for `rip` (the only command touching the
# physical drive); omit it for `scan`/`encode`.
#
# To troubleshoot a failure interactively, override the entrypoint:
#   podman run --rm -it -v "$PWD":/work -w /work --device=/dev/sr0 \
#       --entrypoint bash localhost/media-ripper:latest

FROM docker.io/library/ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

# makemkv PPA (heyarje/makemkv-beta). Fetched live via add-apt-repository so
# the signing key is always current, rather than a hardcoded stale copy.
RUN apt-get update \
 && apt-get install -y --no-install-recommends software-properties-common \
 && add-apt-repository -y ppa:heyarje/makemkv-beta \
 && rm -rf /var/lib/apt/lists/*

# libdvd-pkg builds libdvdcss from source on install and needs a debconf
# answer supplied up front to run non-interactively.
RUN echo 'libdvd-pkg libdvd-pkg/build boolean true' | debconf-set-selections \
 && echo 'libdvd-pkg libdvd-pkg/post-invoke_hook-install boolean true' | debconf-set-selections

# DVD/Blu-ray ripping & transcoding toolchain
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      handbrake-cli mencoder mkvtoolnix ffmpeg \
      libdvd-pkg libavcodec-extra libavformat-dev libavutil-dev libswscale-dev \
      tesseract-ocr tesseract-ocr-por \
      makemkv-bin makemkv-oss \
      lsdvd gddrescue mediainfo nano \
 && dpkg-reconfigure libdvd-pkg \
 && rm -rf /var/lib/apt/lists/*

COPY dvd-ripper.sh /usr/local/bin/dvd-ripper.sh
RUN chmod +x /usr/local/bin/dvd-ripper.sh

ENTRYPOINT ["/usr/local/bin/dvd-ripper.sh"]
