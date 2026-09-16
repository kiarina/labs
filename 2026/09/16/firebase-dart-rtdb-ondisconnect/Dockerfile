# Runs the scenarios on Linux against the emulators on the host.
FROM dart:3.11.0 AS build
WORKDIR /lab
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY bin bin
RUN mkdir -p /out \
 && dart pub get --offline \
 && dart compile exe bin/client.dart -o /out/client \
 && dart compile exe bin/scenarios.dart -o /out/scenarios

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out /lab
WORKDIR /lab
ENV CLIENT=/lab/client
ENTRYPOINT ["/lab/scenarios"]
