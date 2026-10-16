# OpenMaé relay: one static binary in a distroless image, without a shell,
# running as a non-root user.

FROM golang:1.26.5-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relay . \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/relay /relay
# A named volume mounted on /data starts with this owner, so the relay can
# write its QUIC key there.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
VOLUME ["/data"]
# HTTP (behind a TLS reverse proxy) and QUIC.
EXPOSE 8080/tcp 4433/udp
# No shell or curl in the image: the binary checks /healthz itself.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["/relay", "-healthcheck"]
ENTRYPOINT ["/relay"]
