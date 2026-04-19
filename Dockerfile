FROM cm2network/steamcmd:root AS base

# GE-Proton version to install
ARG GE_PROTON_VERSION=GE-Proton10-26

# Install Proton/Wine dependencies
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        xvfb \
        xauth \
        cabextract \
        winbind \
        libfreetype6:i386 \
        libfreetype6 \
        libvulkan1 \
        libvulkan1:i386 \
        procps \
        python3 \
        wget \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id

# Download and extract GE-Proton
RUN mkdir -p /home/steam/proton && \
    wget -q "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_PROTON_VERSION}/${GE_PROTON_VERSION}.tar.gz" \
        -O /tmp/proton.tar.gz && \
    tar -xzf /tmp/proton.tar.gz -C /home/steam/proton --strip-components=1 && \
    rm /tmp/proton.tar.gz && \
    chown -R steam:steam /home/steam/proton

# Create server directory — pre-create all bind-mount target paths as steam:steam
# so Docker does not create them as root on first boot (which would break SteamCMD).
RUN mkdir -p \
    /home/steam/serverfiles/StarRupture/Binaries/Win64/Plugins \
    /home/steam/serverfiles/StarRupture/Saved/SaveGames \
    /home/steam/serverfiles/StarRupture/Saved/Logs \
    && chown -R steam:steam /home/steam/serverfiles

# Copy scripts
COPY --chown=steam:steam entrypoint.sh /home/steam/entrypoint.sh
COPY --chown=steam:steam healthcheck.sh /home/steam/healthcheck.sh
RUN chmod +x /home/steam/entrypoint.sh /home/steam/healthcheck.sh

# Switch to steam user
USER steam
WORKDIR /home/steam

# Game port (UDP). RCON/Steam Query port is TCP and configured via RCON_PORT env var.
EXPOSE 7777/udp

# Persist game files across container restarts
VOLUME ["/home/steam/serverfiles"]

# Health check: verify server process is alive
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD /home/steam/healthcheck.sh

ENTRYPOINT ["/home/steam/entrypoint.sh"]
