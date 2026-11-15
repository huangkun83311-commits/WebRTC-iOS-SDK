FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/bridge-server .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/bridge-server /usr/local/bin/bridge-server
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/bridge-server", "-addr", ":8080"]
