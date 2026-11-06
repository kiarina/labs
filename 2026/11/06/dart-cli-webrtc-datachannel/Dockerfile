# The probe as a Linux container: AOT Dart executable + libdatachannel.
# Both implementations are inside; pick one with --impl.
FROM dart:3.13.7 AS build
RUN apt-get update && apt-get install -y --no-install-recommends cmake build-essential libssl-dev git \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /lab
COPY scripts/build-libdatachannel.sh scripts/
COPY native native
RUN scripts/build-libdatachannel.sh
COPY dart/pubspec.yaml dart/pubspec.lock dart/
RUN cd dart && dart pub get
COPY dart dart
RUN cd dart && dart compile exe bin/probe.dart -o /lab/probe

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /lab/probe /app/probe
COPY --from=build /lab/build/libdatachannel/out/ /app/lib/
ENV LDC_DIR=/app/lib
ENTRYPOINT ["/app/probe"]
