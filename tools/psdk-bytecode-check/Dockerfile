FROM i386/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends wine wine32 ca-certificates && rm -rf /var/lib/apt/lists/*
ENV WINEDEBUG=-all WINEPREFIX=/root/.wine
