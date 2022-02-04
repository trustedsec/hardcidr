FROM bash:latest
RUN apk update
RUN apk add curl bind-tools
COPY . /app/
WORKDIR /app

ENTRYPOINT [ "/usr/local/bin/bash","/app/hardCIDR.sh" ]