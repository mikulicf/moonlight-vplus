FROM golang:1.27.1-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/moonlight-control ./cmd/moonlight-control && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/moonlight-agent ./cmd/moonlight-agent

FROM alpine:3.24

RUN apk add --no-cache ca-certificates && \
    addgroup -S -g 65532 control && \
    adduser -S -D -H -u 65532 -G control control && \
    install -d -o 65532 -g 65532 -m 0700 /data

COPY --from=build --chown=65532:65532 /out/moonlight-control /usr/local/bin/moonlight-control
COPY --from=build --chown=65532:65532 /out/moonlight-agent /usr/local/bin/moonlight-agent

USER 65532:65532
WORKDIR /data
ENTRYPOINT ["moonlight-control"]
