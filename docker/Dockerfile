# Checkmk Community Edition (formerly Raw Edition) for arm64.
#
# Based on https://git.onesystems.ch/monitoring/check_mk/-/tree/master/docker
#
# The .deb this image installs is built by https://github.com/check-mk-arm/check-mk-arm
# because Checkmk publishes no arm64 server packages for any version.
#
# The base distro MUST match the distro the .deb was built for: the package's
# Depends are distro-specific (bookworm pulls libperl5.36, trixie libperl5.40),
# so a .bookworm deb will not install on trixie.
#   Checkmk 2.3.x -> bookworm
#   Checkmk 2.4.x -> trixie
#   Checkmk 2.5.x -> trixie
ARG DISTRO_CODE=bookworm
FROM debian:${DISTRO_CODE}-slim

ARG CMK_VERSION
ARG DISTRO_CODE

LABEL org.opencontainers.image.title="Checkmk Community Edition (arm64)" \
      org.opencontainers.image.description="Checkmk Community Edition (formerly Raw Edition) for Linux ARM64" \
      org.opencontainers.image.version="${CMK_VERSION}" \
      org.opencontainers.image.source="https://github.com/check-mk-arm/check-mk-arm" \
      org.opencontainers.image.licenses="GPL-2.0-only"

# Settable at build time and overridable at runtime (docker run -e KEY=val).
# NOTE: these used to be `ARG X` immediately followed by `ENV X="literal"`,
# which silently discarded every --build-arg. The ${X} indirection is what
# actually wires the two together.
ARG CMK_SITE_ID=cmk
ENV CMK_SITE_ID=${CMK_SITE_ID}
# Set to "on" to enable livestatus via network
ARG CMK_LIVESTATUS_TCP=""
ENV CMK_LIVESTATUS_TCP=${CMK_LIVESTATUS_TCP}
# A random password is generated when this is left empty
ARG CMK_PASSWORD=""
ENV CMK_PASSWORD=${CMK_PASSWORD}
# FQDN of the relay mail server used to send mails
ARG MAIL_RELAY_HOST=""
ENV MAIL_RELAY_HOST=${MAIL_RELAY_HOST}

# The entrypoint writes $TZ into the site's etc/environment, which is the
# per-site mechanism Checkmk expects. Left empty the container stays on UTC.
# (This replaces a build-time hardcoded Europe/Amsterdam.)
ENV TZ=""

# Helper variable so the site can tell it is containerised (used by omd update)
ENV CMK_CONTAINERIZED="TRUE"

RUN set -eux; \
    apt-get update --fix-missing; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        tzdata \
        postfix \
        net-tools \
        inetutils-syslogd \
        openssh-client \
        bsd-mailx \
        libsasl2-modules \
        gnupg2 \
        iputils-ping; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Install Checkmk and let apt resolve its dependencies in one step.
#
# The previous form was `dpkg -i ... ; apt-get install -f -y ; omd version ; ...`
# where every `;` discarded the preceding command's exit status, so a failed
# install still produced a "successful" image. apt handles local .deb files
# directly, which is both simpler and correct.
# check-mk-raw-* up to 2.4, check-mk-community-* from 2.5 (the Raw edition was
# renamed); exactly one of the two is ever present.
COPY check-mk-*.deb /tmp/
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/check-mk-*.deb; \
    omd version; \
    dpkg --print-architecture; \
    AGENT_DEB="$(ls /omd/versions/default/share/check_mk/agents/check-mk-agent_*.deb 2>/dev/null | head -1)"; \
    if [ -n "$AGENT_DEB" ]; then \
        echo "installing bundled Checkmk agent: $AGENT_DEB"; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$AGENT_DEB"; \
    else \
        echo "no bundled agent .deb found — skipping agent install"; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/*.deb

# Ports:
#   5000 - Checkmk GUI
#   6557 - Livestatus (if enabled via "omd config")
EXPOSE 5000 6557

# When all processes of the site are running everything should be fine
HEALTHCHECK --interval=1m --timeout=5s \
    CMD omd status || exit 1

COPY --chmod=0755 docker-entrypoint.sh /

# Starts the entrypoint script and hands over CMD by default
ENTRYPOINT ["/docker-entrypoint.sh"]
