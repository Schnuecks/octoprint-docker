ARG PYTHON_BASE_IMAGE=3.13-slim-trixie

FROM ubuntu AS s6build
ARG S6_RELEASE
ENV S6_VERSION=${S6_RELEASE:-v3.2.3.2}
RUN apt-get update && apt-get install -y curl
RUN echo "$(dpkg --print-architecture)"
WORKDIR /tmp
# s6-overlay v3: one noarch tarball, one per-architecture tarball and the two
# "symlinks" tarballs that keep the classic /usr/bin/with-contenv & co. paths
RUN ARCH= && dpkgArch="$(dpkg --print-architecture)" \
  && case "${dpkgArch##*-}" in \
  amd64) ARCH='x86_64';; \
  arm64) ARCH='aarch64';; \
  armhf) ARCH='armhf';; \
  *) echo "unsupported architecture: $(dpkg --print-architecture)"; exit 1 ;; \
  esac \
  && set -ex \
  && echo $S6_VERSION \
  && for f in s6-overlay-noarch s6-overlay-$ARCH s6-overlay-symlinks-noarch s6-overlay-symlinks-arch; do \
       curl -fsSLO "https://github.com/just-containers/s6-overlay/releases/download/$S6_VERSION/$f.tar.xz"; \
     done


FROM python:${PYTHON_BASE_IMAGE} AS build

ARG octoprint_ref
ENV octoprint_ref=${octoprint_ref:-master}

RUN apt-get update && apt-get install -y \
  avrdude \
  build-essential \
  cmake \
  curl \
  imagemagick \
  ffmpeg \
  fontconfig \
  g++ \
  git \
  haproxy \
  libffi-dev \
  libjpeg-dev \
  libjpeg62-turbo \
  libprotobuf-dev \
  libudev-dev \
  libusb-1.0-0-dev \
  libv4l-dev \
  openssh-client \
  v4l-utils \
  xz-utils \
  zlib1g-dev \
  x265

# unpack s6-overlay v3 (handles the merged /usr of Debian bookworm; the v2 tarball
# replaced the /bin symlink and broke /bin/sh)
COPY --from=s6build /tmp /tmp
RUN cd /tmp \
  && tar -C / -Jxpf s6-overlay-noarch.tar.xz \
  && tar -C / -Jxpf "$(ls s6-overlay-*.tar.xz | grep -vE 'noarch|symlinks')" \
  && tar -C / -Jxpf s6-overlay-symlinks-noarch.tar.xz \
  && tar -C / -Jxpf s6-overlay-symlinks-arch.tar.xz \
  && rm -f s6-overlay-*.tar.xz \
  && test -x /init && test -x /usr/bin/with-contenv

# Install octoprint (the source archive is fetched by BuildKit itself, so a wrong
# version shows up as a clear download error instead of a silent curl failure)
RUN echo "Building OctoPrint ${octoprint_ref}"
ADD https://github.com/OctoPrint/OctoPrint/archive/${octoprint_ref}.tar.gz /tmp/octoprint.tar.gz
RUN mkdir -p /opt/octoprint \
  && tar xzf /tmp/octoprint.tar.gz --strip-components 1 -C /opt/octoprint --no-same-owner \
  && rm /tmp/octoprint.tar.gz

WORKDIR /opt/octoprint
RUN pip install .
RUN mkdir -p /octoprint/octoprint /octoprint/plugins

# Install mjpg-streamer
RUN curl -fsSLO --compressed --retry 3 --retry-delay 10 \
  https://github.com/jacksonliam/mjpg-streamer/archive/master.tar.gz \
  && mkdir /mjpg \
  && tar xzf master.tar.gz -C /mjpg


WORKDIR /mjpg/mjpg-streamer-master/mjpg-streamer-experimental
RUN make
RUN make install

# Copy services into s6 servicedir and set default ENV vars
COPY root /
# s6-overlay v3 executes these scripts directly, so they must be executable
RUN chmod +x /etc/cont-init.d/* /etc/services.d/*/run
ENV CAMERA_DEV=/dev/video0
ENV MJPG_STREAMER_INPUT="-n -r 640x480"
ENV PIP_USER=true
ENV PYTHONUSERBASE=/octoprint/plugins
ENV PATH="${PYTHONUSERBASE}/bin:${PATH}"
# set WORKDIR 
WORKDIR /octoprint

# port to access haproxy frontend
EXPOSE 80

VOLUME /octoprint

ENTRYPOINT ["/init"]
